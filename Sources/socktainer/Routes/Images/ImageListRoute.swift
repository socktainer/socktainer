import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Vapor

struct RESTImageListQuery: Vapor.Content {
    let manifests: Bool?
    let digests: Bool?
}

struct ImageListRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/json", use: ImageListRoute.handler(client: client))
    }
}

struct CustomImageDetail: Decodable {
    public let name: String
}

extension ImageListRoute {
    struct ImageIdentityGroup {
        let image: ClientImage
        let references: [String]
    }

    static func groupByIdentity(_ images: [ClientImage]) -> [ImageIdentityGroup] {
        var groupOrder: [String] = []
        var imagesByDigest: [String: [ClientImage]] = [:]

        for image in images {
            if imagesByDigest[image.digest] == nil {
                groupOrder.append(image.digest)
            }
            imagesByDigest[image.digest, default: []].append(image)
        }

        return groupOrder.compactMap { digest in
            guard let matchingImages = imagesByDigest[digest] else { return nil }
            let orderedImages = matchingImages.sorted { $0.reference < $1.reference }
            guard let representative = orderedImages.first else { return nil }
            return ImageIdentityGroup(
                image: representative,
                references: Array(Set(orderedImages.map(\.reference))).sorted()
            )
        }
    }

    private static func repoDigestReference(name: String, digest: String) -> String {
        if let reference = try? Reference.parse(name) {
            return "\(reference.name)@\(digest)"
        }

        if let atIndex = name.firstIndex(of: "@") {
            return "\(name[..<atIndex])@\(digest)"
        }

        return "\(name)@\(digest)"
    }

    static func repositoryMetadata(
        references: [String],
        rootDigest: String,
        includeDigests: Bool
    ) -> (tags: [String], digests: [String]) {
        let tags = Array(Set(references.filter { !$0.isEmpty })).sorted()
        guard includeDigests else { return (tags, []) }

        let digests = Array(
            Set(
                tags.map {
                    repoDigestReference(name: $0, digest: rootDigest)
                }
            )
        ).sorted()
        return (tags, digests)
    }

    private static func prioritizedManifests(_ manifests: [Descriptor]) -> [Descriptor] {
        let primaryPlatform = requestedOrDefaultPlatform(nil)
        return manifests.enumerated().sorted { left, right in
            if preferredPlatformMatches(
                left.element.platform,
                over: right.element.platform,
                preferredPlatform: primaryPlatform
            ) {
                return true
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func makeOCIDescriptor(
        from descriptor: Descriptor,
        appSupportURL: URL? = nil,
        parentDigest: String? = nil
    ) -> OCIDescriptor {
        let platform = descriptor.platform.map {
            OCIDescriptor.OCIPlatform(
                architecture: $0.architecture,
                os: $0.os,
                osVersion: $0.osVersion,
                osFeatures: $0.osFeatures,
                variant: $0.variant
            )
        }

        let extras: AppleContainerImageStoreResolver.DescriptorExtras? =
            if let appSupportURL, let parentDigest {
                AppleContainerImageStoreResolver.descriptorExtras(
                    appSupportURL: appSupportURL,
                    parentDigest: parentDigest,
                    childDigest: descriptor.digest
                )
            } else {
                nil
            }

        return OCIDescriptor(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            urls: descriptor.urls,
            annotations: descriptor.annotations,
            data: extras?.data,
            platform: platform,
            artifactType: extras?.artifactType
        )
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> [RESTImageSummary] {
        { req in
            let query = try req.query.decode(RESTImageListQuery.self)
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }
            let images = try await client.list()
            let containers = try await ContainerClient().list()
            let includeManifests = query.manifests ?? false
            let includeDigests = query.digests ?? false
            var imagesSummaries: [RESTImageSummary] = []

            for group in groupByIdentity(images) {
                let image = group.image
                let imageIndex = try await image.index()
                let manifests = imageIndex.manifests
                var manifestSummaries: [ImageManifestSummary] = []
                var created = 0
                var size: Int64 = 0
                var labels: [String: String] = [:]
                var foundUsableManifest = false
                var dockerImageID: String?

                for descriptor in prioritizedManifests(manifests) {
                    if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                        referenceType == "attestation-manifest"
                    {
                        continue
                    }

                    guard let platform = descriptor.platform else {
                        continue
                    }

                    let available: Bool
                    let manifest: ContainerizationOCI.Manifest?
                    let config: ContainerizationOCI.Image?
                    do {
                        let resolvedConfig = try await image.config(for: platform)
                        let resolvedManifest = try await image.manifest(for: platform)
                        config = resolvedConfig
                        manifest = resolvedManifest
                        available = true
                    } catch {
                        config = nil
                        manifest = nil
                        available = false
                    }

                    let contentSize = (manifest?.config.size ?? 0) + (manifest?.layers.reduce(0) { $0 + $1.size } ?? 0)
                    let totalSize = descriptor.size + contentSize

                    if includeManifests {
                        let unpackedSize = AppleContainerSnapshotResolver.unpackedSize(
                            appSupportURL: appleContainerAppSupportUrl,
                            descriptor: descriptor
                        )
                        let platformSummary = descriptor.platform.map {
                            OCIDescriptor.OCIPlatform(
                                architecture: $0.architecture,
                                os: $0.os,
                                osVersion: $0.osVersion,
                                osFeatures: $0.osFeatures,
                                variant: $0.variant
                            )
                        }

                        manifestSummaries.append(
                            ImageManifestSummary(
                                ID: descriptor.digest,
                                Descriptor: makeOCIDescriptor(
                                    from: descriptor,
                                    appSupportURL: appleContainerAppSupportUrl,
                                    parentDigest: image.descriptor.digest
                                ),
                                Available: available,
                                Kind: "image",
                                Size: .init(Total: totalSize + unpackedSize, Content: contentSize),
                                ImageData: .init(
                                    Platform: platformSummary,
                                    Containers: [],
                                    Size: .init(Unpacked: unpackedSize)
                                ),
                                AttestationData: nil
                            )
                        )
                    }

                    if !foundUsableManifest, let config, available {
                        created = Int(AppleContainerTimestampResolver.unixTimestampSeconds(config.created))
                        size = totalSize
                        labels = config.config?.labels ?? [:]
                        dockerImageID = manifest?.config.digest
                        foundUsableManifest = true
                    }
                }

                let repositoryMetadata = repositoryMetadata(
                    references: group.references,
                    rootDigest: image.descriptor.digest,
                    includeDigests: includeDigests
                )
                let references = Set(group.references)
                let containersUsingImage = containers.filter {
                    references.contains($0.configuration.image.reference)
                }
                let summary = RESTImageSummary(
                    Id: dockerImageID ?? image.digest,
                    ParentId: "",
                    RepoTags: repositoryMetadata.tags,
                    RepoDigests: repositoryMetadata.digests,
                    Created: created,
                    Size: size,
                    SharedSize: -1,
                    Labels: labels,
                    Containers: containersUsingImage.count,
                    Manifests: includeManifests ? manifestSummaries : nil,
                    Descriptor: makeOCIDescriptor(
                        from: image.descriptor,
                        appSupportURL: appleContainerAppSupportUrl
                    )
                )

                imagesSummaries.append(summary)
            }

            return imagesSummaries
        }
    }
}
