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

            for image in images {
                let details: ImageDetail = try await image.details()
                let imageIndex = try await image.index()
                let manifests = imageIndex.manifests
                var manifestSummaries: [ImageManifestSummary] = []
                var created = 0
                var size: Int64 = 0
                var labels: [String: String] = [:]
                var foundUsableManifest = false

                for descriptor in manifests {
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
                                    parentDigest: details.index.digest
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
                        foundUsableManifest = true
                    }
                }

                let repoTags = details.name.isEmpty ? [] : [details.name]
                let repoDigests = includeDigests && image.reference.contains("@sha256:") ? [image.reference] : []
                let containersUsingImage = containers.filter { $0.configuration.image.reference == image.reference || $0.configuration.image.reference == details.name }
                let summary = RESTImageSummary(
                    Id: image.digest,
                    ParentId: "",
                    RepoTags: repoTags,
                    RepoDigests: repoDigests,
                    Created: created,
                    Size: size,
                    SharedSize: -1,
                    Labels: labels,
                    Containers: containersUsingImage.count,
                    Manifests: includeManifests ? manifestSummaries : nil,
                    Descriptor: makeOCIDescriptor(
                        from: details.index,
                        appSupportURL: appleContainerAppSupportUrl
                    )
                )

                imagesSummaries.append(summary)
            }

            return imagesSummaries
        }
    }
}
