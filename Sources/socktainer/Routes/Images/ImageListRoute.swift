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
    let runnableImageSelector: RunnableImageSelector
    let containerListProvider:
        @Sendable () async throws
            -> [ContainerSnapshot]

    init(
        client: ClientImageProtocol,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector(),
        containerListProvider:
            @escaping @Sendable () async throws
            -> [ContainerSnapshot] = { try await ContainerClient().list() }
    ) {
        self.client = client
        self.runnableImageSelector = runnableImageSelector
        self.containerListProvider = containerListProvider
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/images/json",
            use: ImageListRoute.handler(
                client: client,
                runnableImageSelector: runnableImageSelector,
                containerListProvider: containerListProvider
            )
        )
    }
}

struct CustomImageDetail: Decodable {
    public let name: String
}

extension ImageListRoute {
    struct DockerConfigRowMetadata: Sendable {
        let created: Int
        let size: Int64
        let labels: [String: String]
        let containers: Int
        let manifestDigests: Set<String>
    }

    static func splitByPersistedTagIdentity(
        _ summaries: [RESTImageSummary],
        selections: [DockerTagConfigSelection],
        metadataByRoot: [String: [String: DockerConfigRowMetadata]] = [:]
    ) -> [RESTImageSummary] {
        let byRoot = Dictionary(grouping: selections, by: \.rootDigest)
        return summaries.flatMap { summary -> [RESTImageSummary] in
            guard let root = summary.Descriptor?.digest,
                let rootSelections = byRoot[root],
                !rootSelections.isEmpty
            else { return [summary] }
            return splitSummary(
                summary,
                rootSelections: rootSelections,
                metadataByConfig: metadataByRoot[root] ?? [:]
            )
        }
    }

    static func splitSummary(
        _ summary: RESTImageSummary,
        rootSelections: [DockerTagConfigSelection],
        metadataByConfig: [String: DockerConfigRowMetadata] = [:]
    ) -> [RESTImageSummary] {
        let selectedTags = Set(rootSelections.map(\.reference))
        let fallbackTags = summary.RepoTags.filter {
            !selectedTags.contains($0)
        }
        let byConfig = Dictionary(
            grouping: rootSelections,
            by: \.configDigest
        )
        var rows: [RESTImageSummary] = []
        for config in byConfig.keys.sorted() {
            guard let members = byConfig[config] else { continue }
            let tags =
                members.map(\.reference)
                + (config == summary.Id ? fallbackTags : [])
            let metadata = metadataByConfig[config]
            let manifests =
                metadata.map { metadata in
                    summary.Manifests?.filter {
                        metadata.manifestDigests.contains($0.ID ?? "")
                            || metadata.manifestDigests.contains(
                                $0.AttestationData?.For ?? ""
                            )
                    } ?? []
                } ?? summary.Manifests
            rows.append(
                RESTImageSummary(
                    Id: config,
                    ParentId: summary.ParentId,
                    RepoTags: Array(Set(tags)).sorted(),
                    RepoDigests: config == summary.Id
                        ? summary.RepoDigests : [],
                    Created: metadata?.created ?? summary.Created,
                    Size: metadata?.size ?? summary.Size,
                    SharedSize: summary.SharedSize,
                    Labels: metadata?.labels ?? summary.Labels,
                    Containers: metadata?.containers ?? summary.Containers,
                    Manifests: manifests,
                    Descriptor: summary.Descriptor
                )
            )
        }
        if !fallbackTags.isEmpty,
            byConfig[summary.Id] == nil
        {
            rows.append(
                RESTImageSummary(
                    Id: summary.Id,
                    ParentId: summary.ParentId,
                    RepoTags: fallbackTags,
                    RepoDigests: summary.RepoDigests,
                    Created: summary.Created,
                    Size: summary.Size,
                    SharedSize: summary.SharedSize,
                    Labels: summary.Labels,
                    Containers: summary.Containers,
                    Manifests: summary.Manifests,
                    Descriptor: summary.Descriptor
                )
            )
        }
        return rows.isEmpty ? [summary] : rows
    }
    static func isDockerImageRoot(
        _ descriptors: [ResolvedImageDescriptor]
    ) -> Bool {
        descriptors.contains { $0.runnableVariant != nil }
    }

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

    static func containerCount(
        usingRootDigest rootDigest: String,
        in containers: [ContainerSnapshot]
    ) -> Int {
        ContainerImageIdentity.containers(
            containers,
            usingRootDigest: rootDigest
        ).count
    }

    static func repositoryMetadata(
        references: [String],
        rootDigest: String,
        includeDigests: Bool,
        validRepositoryDigests: Set<String>? = nil
    ) -> (tags: [String], digests: [String]) {
        let tags = Array(
            Set(
                references.filter { reference in
                    guard !reference.isEmpty,
                        !DockerImageReferenceSemantics
                            .isInternalReference(reference),
                        !DockerImageReferenceSemantics.isBareSHA256Identifier(
                            reference
                        )
                    else {
                        return false
                    }
                    return (try? Reference.parse(reference))?.digest == nil
                }
            )
        ).sorted()
        guard includeDigests else { return (tags, []) }

        let validDigests =
            validRepositoryDigests
            ?? [rootDigest.lowercased()]
        let storedRepositoryDigests = references.filter { reference in
            guard !reference.isEmpty,
                !DockerImageReferenceSemantics
                    .isInternalReference(reference),
                !DockerImageReferenceSemantics.isBareSHA256Identifier(
                    reference
                ),
                let parsed = try? Reference.parse(reference),
                let digest = parsed.digest,
                validDigests.contains(digest.lowercased())
            else {
                return false
            }
            return true
        }

        let digests = Array(
            Set(storedRepositoryDigests)
        ).sorted()
        return (tags, digests)
    }

    /// Apple stores references by OCI root index, while Docker's local image
    /// rows are keyed by the selected config digest. Distinct (for example,
    /// attested and plain) roots can therefore be one Docker image ID. Collapse
    /// them after resolving each root so tags and container attribution do not
    /// disappear behind whichever root happened to be enumerated first.
    static func mergeByDockerImageID(
        _ summaries: [RESTImageSummary]
    ) -> [RESTImageSummary] {
        var order: [String] = []
        var grouped: [String: [RESTImageSummary]] = [:]
        for summary in summaries {
            if grouped[summary.Id] == nil { order.append(summary.Id) }
            grouped[summary.Id, default: []].append(summary)
        }

        return order.compactMap { id in
            guard let candidates = grouped[id] else { return nil }
            let orderedCandidates = candidates.sorted(by: {
                ($0.Descriptor?.digest ?? "")
                    < ($1.Descriptor?.digest ?? "")
            })
            guard let representative = orderedCandidates.first else {
                return nil
            }
            let orderedManifests = orderedCandidates.flatMap {
                $0.Manifests ?? []
            }
            var seenManifestIDs: Set<String> = []
            var mergedManifests: [ImageManifestSummary] = []
            // Every per-root list is already in host preference order. Merge
            // roots deterministically while keeping all runnable manifests
            // ahead of attestations, then de-duplicate the same immutable
            // descriptor without re-sorting by digest and losing that order.
            for kindRank in 0...2 {
                for manifest in orderedManifests
                where manifestKindRank(manifest.Kind) == kindRank {
                    if let manifestID = manifest.ID {
                        guard seenManifestIDs.insert(manifestID).inserted else {
                            continue
                        }
                    }
                    mergedManifests.append(manifest)
                }
            }
            let manifests =
                candidates.allSatisfy { $0.Manifests == nil }
                ? nil
                : mergedManifests
            return RESTImageSummary(
                Id: id,
                ParentId: representative.ParentId,
                RepoTags: Array(Set(candidates.flatMap(\.RepoTags))).sorted(),
                RepoDigests: Array(
                    Set(candidates.flatMap(\.RepoDigests))
                ).sorted(),
                Created: representative.Created,
                Size: representative.Size,
                SharedSize: representative.SharedSize,
                Labels: representative.Labels,
                Containers: candidates.reduce(0) { $0 + $1.Containers },
                Manifests: manifests,
                Descriptor: representative.Descriptor
            )
        }
    }

    private static func manifestKindRank(_ kind: String?) -> Int {
        switch kind {
        case "image": 0
        case "attestation": 1
        default: 2
        }
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
            artifactType: extras?.artifactType ?? descriptor.artifactType
        )
    }

    static func handler(
        client: ClientImageProtocol,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector(),
        containerListProvider:
            @escaping @Sendable () async throws
            -> [ContainerSnapshot] = { try await ContainerClient().list() }
    ) -> @Sendable (Request) async throws -> [RESTImageSummary] {
        { req in
            let query = try req.query.decode(RESTImageListQuery.self)
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }
            let inventory = try await (client as? any ImageStoreInventoryProviding)?.imageStoreInventory(includeSystemImages: false)
            let images: [ClientImage]
            if let inventory {
                images = inventory.images
            } else {
                images = try await client.list()
            }
            let containers = try await containerListProvider()
            var usageByRootAndConfig: [String: [String: Int]] = [:]
            for container in containers {
                let configDigest = await ContainerImageIdentity.configDigest(
                    for: container,
                    runnableImageSelector: runnableImageSelector
                )
                let rootDigest = container.configuration.image.digest
                usageByRootAndConfig[rootDigest, default: [:]][
                    configDigest,
                    default: 0
                ] += 1
            }
            let includeManifests = query.manifests ?? false
            let includeDigests = query.digests ?? false
            var imagesSummaries: [RESTImageSummary] = []
            var metadataByRoot: [String: [String: DockerConfigRowMetadata]] = [:]

            for group in groupByIdentity(images) {
                let image = group.image
                let resolvedDescriptors =
                    try await runnableImageSelector
                    .descriptors(for: image)
                // An OCI artifact collection is not a Docker image. Missing
                // runnable content may retain a legacy root fallback, but a
                // root whose descriptors are all positively classified as
                // artifacts must never appear in `docker image ls`.
                guard isDockerImageRoot(resolvedDescriptors) else {
                    continue
                }
                var manifestSummaries: [ImageManifestSummary] = []
                var created = 0
                var size: Int64 = 0
                var labels: [String: String] = [:]
                let selectedVariant = runnableImageSelector.selectVariant(
                    from: resolvedDescriptors,
                    requestedPlatform: nil
                )
                var configMetadata: [String: DockerConfigRowMetadata] = [:]
                for resolved in resolvedDescriptors {
                    guard let variant = resolved.runnableVariant else {
                        continue
                    }
                    let configDigest = variant.manifest.config.digest
                    if let existing = configMetadata[configDigest] {
                        configMetadata[configDigest] = DockerConfigRowMetadata(
                            created: existing.created,
                            size: existing.size,
                            labels: existing.labels,
                            containers: existing.containers,
                            manifestDigests: existing.manifestDigests.union([
                                variant.descriptor.digest
                            ])
                        )
                    } else {
                        configMetadata[configDigest] = DockerConfigRowMetadata(
                            created: Int(
                                AppleContainerTimestampResolver
                                    .unixTimestampSeconds(
                                        variant.config.created
                                    )
                            ),
                            size: variant.totalSize,
                            labels: variant.config.config?.labels ?? [:],
                            containers: usageByRootAndConfig[image.digest]?[
                                configDigest
                            ] ?? 0,
                            manifestDigests: [variant.descriptor.digest]
                        )
                    }
                }
                metadataByRoot[image.digest] = configMetadata

                if let selectedVariant {
                    created = Int(
                        AppleContainerTimestampResolver.unixTimestampSeconds(
                            selectedVariant.config.created
                        )
                    )
                    size = selectedVariant.totalSize
                    labels = selectedVariant.config.config?.labels ?? [:]
                }

                for resolvedDescriptor
                    in runnableImageSelector
                    .descriptorsInDeterministicPreferenceOrder(
                        resolvedDescriptors
                    )
                {
                    let descriptor = resolvedDescriptor.descriptor
                    let kind =
                        resolvedDescriptor.kind == .artifact
                        ? "attestation" : "image"
                    let available =
                        resolvedDescriptor.kind == .artifact
                        ? resolvedDescriptor.documentAvailable
                        : resolvedDescriptor.runnableVariant != nil
                    let contentSize = resolvedDescriptor.contentSize
                    let totalSize = resolvedDescriptor.totalSize

                    if includeManifests {
                        let unpackedSize =
                            kind == "image"
                            ? AppleContainerSnapshotResolver.unpackedSize(
                                appSupportURL: appleContainerAppSupportUrl,
                                descriptor: descriptor
                            ) : 0
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
                                Kind: kind,
                                Size: .init(Total: totalSize + unpackedSize, Content: contentSize),
                                ImageData: kind == "image"
                                    ? .init(
                                        Platform: platformSummary,
                                        Containers: [],
                                        Size: .init(Unpacked: unpackedSize)
                                    ) : nil,
                                AttestationData: kind == "attestation"
                                    ? .init(
                                        For: resolvedDescriptor
                                            .artifactSubjectDigest ?? ""
                                    ) : nil
                            )
                        )
                    }
                }

                let repositoryMetadata = repositoryMetadata(
                    references: group.references,
                    rootDigest: image.descriptor.digest,
                    includeDigests: includeDigests,
                    validRepositoryDigests:
                        RunnableImageSelector.dockerIdentityDigests(
                            rootDigest: image.digest,
                            descriptors: resolvedDescriptors
                        )
                )
                let summary = RESTImageSummary(
                    Id: selectedVariant?.manifest.config.digest ?? image.digest,
                    ParentId: "",
                    RepoTags: repositoryMetadata.tags,
                    RepoDigests: repositoryMetadata.digests,
                    Created: created,
                    Size: size,
                    SharedSize: -1,
                    Labels: labels,
                    Containers: containerCount(
                        usingRootDigest: image.digest,
                        in: containers
                    ),
                    Manifests: includeManifests ? manifestSummaries : nil,
                    Descriptor: makeOCIDescriptor(
                        from: image.descriptor,
                        appSupportURL: appleContainerAppSupportUrl
                    )
                )

                imagesSummaries.append(summary)
            }

            let selections = inventory?.tagConfigSelections ?? []
            return mergeByDockerImageID(
                splitByPersistedTagIdentity(
                    imagesSummaries,
                    selections: selections,
                    metadataByRoot: metadataByRoot
                )
            )
        }
    }
}
