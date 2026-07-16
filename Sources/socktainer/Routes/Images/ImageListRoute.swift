import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Vapor

struct RESTImageListQuery: Vapor.Content {
    let manifests: Bool?
    let digests: Bool?
    let filters: String?
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
            // moby validates the filters before doing any listing work.
            let filters = try DockerImageFilterUtility.parseImageListFilters(filterParam: query.filters, logger: req.logger)
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }
            let images = try await client.list()
            let containers = try await ContainerClient().list()
            let includeManifests = query.manifests ?? false
            let includeDigests = query.digests ?? false
            var imagesSummaries: [RESTImageSummary] = []

            for image in images {
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
                        foundUsableManifest = true
                    }
                }

                let repoTags = image.reference.isEmpty ? [] : [image.reference]
                let repoDigests = includeDigests && image.reference.contains("@sha256:") ? [image.reference] : []
                let containersUsingImage = containers.filter { $0.configuration.image.reference == image.reference }
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
                        from: image.descriptor,
                        appSupportURL: appleContainerAppSupportUrl
                    )
                )

                imagesSummaries.append(summary)
            }

            return try ImageListRoute.applyFilters(imagesSummaries, filters: filters)
        }
    }

    /// Applies the `dangling` and `reference` image-ls filters. Different keys
    /// AND together, matching moby.
    static func applyFilters(_ summaries: [RESTImageSummary], filters: [String: [String]]) throws -> [RESTImageSummary] {
        var result = summaries
        if let dangling = filters["dangling"], !dangling.isEmpty {
            // moby's filters.GetBoolOrDefault recognizes only 0/1/true/false
            // here (stricter than the MobyBool query-parameter semantics) and
            // rejects an unrecognized or conflicting value with a 400.
            let isTrue = dangling.contains("1") || dangling.contains("true")
            let isFalse = dangling.contains("0") || dangling.contains("false")
            guard isTrue != isFalse else {
                throw Abort(.badRequest, reason: "invalid filter 'dangling=[\(dangling.joined(separator: " "))]'")
            }
            result = result.filter { ImageListFilter.isDangling(repoTags: $0.RepoTags) == isTrue }
        }
        if let patterns = filters["reference"], !patterns.isEmpty {
            result = result.filter { ImageListFilter.referenceMatches(patterns: patterns, repoTags: $0.RepoTags) }
        }
        return result
    }
}
