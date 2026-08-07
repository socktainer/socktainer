import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Vapor

struct SystemDFResponse: Vapor.Content {
    let LayersSize: Int64?
    let Images: [RESTImageSummary]?
    let Containers: [RESTContainerSummary]?
    let Volumes: [Volume]?
    let BuildCache: [RESTBuildCache]?
}

struct SystemDFQuery: Vapor.Content {
    let type: [String]?
}

/// Narrow seam for `buildContainerSummaries`' per-container disk usage lookup — kept separate
/// from `ClientContainerProtocol` (implemented by ~20 test mocks across the suite) so this one
/// method can be stubbed in tests without touching every other container route's fixtures.
protocol ContainerDiskUsageProviding: Sendable {
    func diskUsage(id: String) async throws -> UInt64
}

struct ContainerClientDiskUsageProvider: ContainerDiskUsageProviding {
    func diskUsage(id: String) async throws -> UInt64 {
        try await ContainerClient().diskUsage(id: id)
    }
}

/// Narrow seam for the total image-layer disk usage figure, kept separate from
/// `ClientImageProtocol` for the same reason as `ContainerDiskUsageProviding` above.
protocol ImageLayerDiskUsageProviding: Sendable {
    func calculateDiskUsage(activeReferences: Set<String>) async throws -> (
        totalCount: Int, activeCount: Int, totalSize: UInt64, reclaimableSize: UInt64
    )
}

struct ClientImageLayerDiskUsageProvider: ImageLayerDiskUsageProviding {
    func calculateDiskUsage(activeReferences: Set<String>) async throws -> (
        totalCount: Int, activeCount: Int, totalSize: UInt64, reclaimableSize: UInt64
    ) {
        try await ClientImage.calculateDiskUsage(activeReferences: activeReferences)
    }
}

struct DockerImageSummaryMetadata: Sendable {
    let configDigest: String
    let identityDigests: Set<String>
    let created: Int
    let size: Int64
    let labels: [String: String]
    let configRows: [String: ImageListRoute.DockerConfigRowMetadata]

    init(
        configDigest: String,
        identityDigests: Set<String>,
        created: Int,
        size: Int64,
        labels: [String: String],
        configRows: [String: ImageListRoute.DockerConfigRowMetadata] = [:]
    ) {
        self.configDigest = configDigest
        self.identityDigests = identityDigests
        self.created = created
        self.size = size
        self.labels = labels
        self.configRows = configRows
    }
}

protocol DockerImageSummaryMetadataProviding: Sendable {
    func metadata(for image: ClientImage) async throws -> DockerImageSummaryMetadata
}

struct LiveDockerImageSummaryMetadataProvider:
    DockerImageSummaryMetadataProviding
{
    let runnableImageSelector: RunnableImageSelector

    init(
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector()
    ) {
        self.runnableImageSelector = runnableImageSelector
    }

    func metadata(for image: ClientImage) async throws -> DockerImageSummaryMetadata {
        let descriptors = try await runnableImageSelector.descriptors(
            for: image
        )
        let selectedVariant = runnableImageSelector.selectVariant(
            from: descriptors,
            requestedPlatform: nil
        )
        let dockerImageID =
            selectedVariant?.manifest.config.digest
            ?? image.digest
        let created = Int(
            AppleContainerTimestampResolver.unixTimestampSeconds(
                selectedVariant?.config.created
            )
        )
        var configRows: [String: ImageListRoute.DockerConfigRowMetadata] = [:]
        for descriptor in descriptors {
            guard let variant = descriptor.runnableVariant else { continue }
            let configDigest = variant.manifest.config.digest
            if configRows[configDigest] == nil {
                configRows[configDigest] = .init(
                    created: Int(
                        AppleContainerTimestampResolver.unixTimestampSeconds(
                            variant.config.created
                        )
                    ),
                    size: variant.totalSize,
                    labels: variant.config.config?.labels ?? [:],
                    containers: 0,
                    manifestDigests: [variant.descriptor.digest]
                )
            } else if let existing = configRows[configDigest] {
                configRows[configDigest] = .init(
                    created: existing.created,
                    size: existing.size,
                    labels: existing.labels,
                    containers: existing.containers,
                    manifestDigests: existing.manifestDigests.union([
                        variant.descriptor.digest
                    ])
                )
            }
        }
        return DockerImageSummaryMetadata(
            configDigest: dockerImageID,
            identityDigests: RunnableImageSelector.dockerIdentityDigests(
                rootDigest: image.digest,
                descriptors: descriptors
            ),
            created: created,
            size: selectedVariant?.totalSize ?? 0,
            labels: selectedVariant?.config.config?.labels ?? [:],
            configRows: configRows
        )
    }
}

struct SystemDFRoute: RouteCollection {
    let imageClient: ClientImageProtocol
    let containerClient: ClientContainerProtocol
    let volumeClient: ClientVolumeProtocol
    let builderClient: ClientBuilderProtocol
    let diskUsageProvider: ContainerDiskUsageProviding
    let imageLayerDiskUsageProvider: ImageLayerDiskUsageProviding
    let imageInventoryProvider: (any ImageStoreInventoryProviding)?
    let imageMetadataProvider: any ContainerImageMetadataProviding
    let imageSummaryMetadataProvider: any DockerImageSummaryMetadataProviding

    init(
        imageClient: ClientImageProtocol,
        containerClient: ClientContainerProtocol,
        volumeClient: ClientVolumeProtocol,
        builderClient: ClientBuilderProtocol,
        diskUsageProvider: ContainerDiskUsageProviding,
        imageLayerDiskUsageProvider: ImageLayerDiskUsageProviding,
        imageInventoryProvider: (any ImageStoreInventoryProviding)? = nil,
        imageMetadataProvider: any ContainerImageMetadataProviding = StoredContainerImageMetadataProvider(),
        imageSummaryMetadataProvider: any DockerImageSummaryMetadataProviding = LiveDockerImageSummaryMetadataProvider()
    ) {
        self.imageClient = imageClient
        self.containerClient = containerClient
        self.volumeClient = volumeClient
        self.builderClient = builderClient
        self.diskUsageProvider = diskUsageProvider
        self.imageLayerDiskUsageProvider = imageLayerDiskUsageProvider
        self.imageInventoryProvider = imageInventoryProvider
        self.imageMetadataProvider = imageMetadataProvider
        self.imageSummaryMetadataProvider = imageSummaryMetadataProvider
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/system/df", use: handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let query = try req.query.decode(SystemDFQuery.self)
        let requestedTypes = Set(query.type ?? [])
        let includeAll = requestedTypes.isEmpty

        async let containers = containerClient.list(showAll: true, filters: [:])
        async let volumes = volumeClient.list(filters: nil, logger: req.logger)

        let inventory: ImageStoreInventory
        if let imageInventoryProvider {
            inventory = try await imageInventoryProvider.imageStoreInventory(
                includeSystemImages: true
            )
        } else {
            let images = try await imageClient.list(includeSystemImages: true)
            inventory = ImageStoreInventory(
                images: images,
                physicalReferencesByRootDigest: Dictionary(
                    grouping: images,
                    by: \.digest
                ).mapValues { Set($0.map(\.reference)) }
            )
        }
        let (allContainers, allVolumes) = try await (containers, volumes)
        let allImages = inventory.images
        let usageByImageDigest = ContainerImageIdentity.usageByRootDigest(allContainers)
        var usageByRootAndConfig: [String: [String: Int]] = [:]
        for container in allContainers {
            let metadata = await imageMetadataProvider.metadata(for: container)
            usageByRootAndConfig[metadata.rootDigest, default: [:]][
                metadata.configDigest,
                default: 0
            ] += 1
        }

        let imageSummaries: [RESTImageSummary]?
        if includeAll || requestedTypes.contains("image") {
            imageSummaries = try await Self.buildImageSummaries(
                images: allImages,
                usageByImageDigest: usageByImageDigest,
                usageByRootAndConfig: usageByRootAndConfig,
                metadataProvider: imageSummaryMetadataProvider,
                tagSelections: inventory.tagConfigSelections
            )
        } else {
            imageSummaries = nil
        }

        let containerSummaries: [RESTContainerSummary]?
        if includeAll || requestedTypes.contains("container") {
            containerSummaries = try await Self.buildContainerSummaries(
                containers: allContainers,
                diskUsageProvider: diskUsageProvider,
                imageMetadataProvider: imageMetadataProvider
            )
        } else {
            containerSummaries = nil
        }

        let volumeSummaries: [Volume]?
        if includeAll || requestedTypes.contains("volume") {
            volumeSummaries = try await Self.buildVolumeSummaries(volumes: allVolumes, containers: allContainers)
        } else {
            volumeSummaries = nil
        }

        let layersSize: Int64?
        if includeAll || requestedTypes.contains("image") {
            let activeReferences = ContainerImageIdentity.activeStoreReferences(
                physicalReferencesByRootDigest: inventory.physicalReferencesByRootDigest,
                containers: allContainers
            )
            let usage = try await imageLayerDiskUsageProvider.calculateDiskUsage(activeReferences: activeReferences)
            layersSize = Int64(clamping: usage.totalSize)
        } else {
            layersSize = nil
        }

        // NOTE: This type is optional at the moment
        let buildCache: [RESTBuildCache]?
        if includeAll {
            buildCache = []
        } else if requestedTypes.contains("build-cache") {
            buildCache = try await builderClient.diskUsage(logger: req.logger).map {
                RESTBuildCache(
                    ID: $0.id,
                    Parents: $0.parents,
                    kind: $0.kind,
                    Description: $0.description,
                    InUse: $0.inUse,
                    Shared: $0.shared,
                    Size: $0.size,
                    CreatedAt: $0.createdAt,
                    LastUsedAt: $0.lastUsedAt,
                    UsageCount: $0.usageCount
                )
            }
        } else {
            buildCache = nil
        }

        let response = SystemDFResponse(
            LayersSize: layersSize,
            Images: imageSummaries,
            Containers: containerSummaries,
            Volumes: volumeSummaries,
            BuildCache: buildCache
        )

        return try await response.encodeResponse(status: .ok, for: req)
    }
}

extension SystemDFRoute {
    fileprivate static func buildImageSummaries(
        images: [ClientImage],
        usageByImageDigest: [String: Int],
        usageByRootAndConfig: [String: [String: Int]] = [:],
        metadataProvider: any DockerImageSummaryMetadataProviding,
        tagSelections: [DockerTagConfigSelection] = []
    ) async throws -> [RESTImageSummary] {
        let selectionsByRoot = Dictionary(
            grouping: tagSelections,
            by: \.rootDigest
        )
        return try await withThrowingTaskGroup(
            of: (
                String,
                RESTImageSummary,
                [String: ImageListRoute.DockerConfigRowMetadata]
            ).self
        ) { group in
            for identityGroup in ImageListRoute.groupByIdentity(images) {
                group.addTask {
                    let image = identityGroup.image
                    let imageMetadata = try await metadataProvider.metadata(
                        for: image
                    )

                    let repositoryMetadata = ImageListRoute.repositoryMetadata(
                        references: identityGroup.references,
                        rootDigest: image.digest,
                        includeDigests: true,
                        validRepositoryDigests: imageMetadata.identityDigests
                    )
                    let containerCount = usageByImageDigest[image.digest] ?? 0

                    let configRows = imageMetadata.configRows.map { config, metadata in
                        (
                            config,
                            ImageListRoute.DockerConfigRowMetadata(
                                created: metadata.created,
                                size: metadata.size,
                                labels: metadata.labels,
                                containers: usageByRootAndConfig[image.digest]?[
                                    config
                                ] ?? 0,
                                manifestDigests: metadata.manifestDigests
                            )
                        )
                    }.reduce(into: [String: ImageListRoute.DockerConfigRowMetadata]()) {
                        $0[$1.0] = $1.1
                    }

                    return (
                        image.digest,
                        RESTImageSummary(
                            Id: imageMetadata.configDigest,
                            ParentId: "",
                            RepoTags: repositoryMetadata.tags,
                            RepoDigests: repositoryMetadata.digests,
                            Created: imageMetadata.created,
                            Size: imageMetadata.size,
                            SharedSize: 0,
                            Labels: imageMetadata.labels,
                            Containers: containerCount,
                            Manifests: nil,
                            Descriptor: nil
                        ), configRows
                    )
                }
            }

            var summaries: [RESTImageSummary] = []
            for try await (rootDigest, summary, configRows) in group {
                summaries.append(
                    contentsOf: ImageListRoute.splitSummary(
                        summary,
                        rootSelections: selectionsByRoot[rootDigest] ?? [],
                        metadataByConfig: configRows
                    )
                )
            }
            return ImageListRoute.mergeByDockerImageID(summaries).sorted {
                ($0.RepoTags.first ?? $0.Id) < ($1.RepoTags.first ?? $1.Id)
            }
        }
    }

    fileprivate static func buildContainerSummaries(
        containers: [ContainerSnapshot],
        diskUsageProvider: ContainerDiskUsageProviding,
        imageMetadataProvider: any ContainerImageMetadataProviding
    ) async throws -> [RESTContainerSummary] {
        try await withThrowingTaskGroup(of: RESTContainerSummary.self) { group in
            for container in containers {
                group.addTask {
                    let size = try await diskUsageProvider.diskUsage(id: container.id)
                    let imageMetadata = await imageMetadataProvider.metadata(
                        for: container
                    )
                    return containerSummary(
                        from: container,
                        size: Int64(clamping: size),
                        imageMetadata: imageMetadata
                    )
                }
            }

            var summaries: [RESTContainerSummary] = []
            for try await summary in group {
                summaries.append(summary)
            }
            return summaries.sorted { $0.Created > $1.Created }
        }
    }

    fileprivate static func buildVolumeSummaries(
        volumes: [Volume],
        containers: [ContainerSnapshot]
    ) async throws -> [Volume] {
        var refCounts: [String: Int64] = [:]
        for container in containers {
            for mount in container.configuration.mounts {
                if mount.isVolume, let name = mount.volumeName {
                    refCounts[name, default: 0] += 1
                }
            }
        }
        let normalizedRefCounts = refCounts

        return try await withThrowingTaskGroup(of: Volume.self) { group in
            for volume in volumes {
                group.addTask {
                    let size = try await ClientVolume.volumeDiskUsage(name: volume.Name)
                    return Volume(
                        Name: volume.Name,
                        Driver: volume.Driver,
                        Mountpoint: volume.Mountpoint,
                        CreatedAt: volume.CreatedAt,
                        Status: volume.Status,
                        Labels: volume.Labels,  // already restored by ClientVolumeService.convert()
                        Scope: volume.Scope,
                        ClusterVolume: volume.ClusterVolume,
                        Options: volume.Options,
                        UsageData: VolumeUsageData(
                            Size: Int64(clamping: size),
                            RefCount: normalizedRefCounts[volume.Name] ?? 0
                        )
                    )
                }
            }

            var enrichedVolumes: [Volume] = []
            for try await volume in group {
                enrichedVolumes.append(volume)
            }
            return enrichedVolumes.sorted { $0.Name < $1.Name }
        }
    }

    fileprivate static func containerSummary(
        from container: ContainerSnapshot,
        size: Int64,
        imageMetadata: DockerContainerImageMetadata
    ) -> RESTContainerSummary {
        let ports = container.configuration.publishedPorts.map { port in
            ContainerPort(
                IP: port.hostAddress.description,
                PrivatePort: Int(port.containerPort),
                PublicPort: Int(port.hostPort),
                type: port.proto.rawValue
            )
        }

        let networkMode = container.networks.first?.network ?? "default"
        let networkSettings = Dictionary(
            container.networks.map { attachment in
                (attachment.network, ContainerEndpointSettings.live(attachment))
            },
            uniquingKeysWith: { first, _ in first }
        )

        let mounts = container.configuration.mounts.map { mount in
            let mountType: String
            let mountName: String?
            let driver: String?

            switch mount.type {
            case .block:
                mountType = "bind"
                mountName = nil
                driver = nil
            case .volume(let name, _, _, _):
                mountType = "volume"
                mountName = name
                driver = "local"
            case .virtiofs:
                mountType = "bind"
                mountName = nil
                driver = nil
            case .tmpfs:
                mountType = "tmpfs"
                mountName = nil
                driver = nil
            }

            let isReadOnly = mount.options.readonly
            return ContainerMountPoint(
                type: mountType,
                name: mountName,
                source: mount.source,
                destination: mount.destination,
                driver: driver,
                mode: isReadOnly ? "ro" : "rw",
                rw: !isReadOnly,
                propagation: ""
            )
        }

        let createdTimestamp = AppleContainerTimestampResolver.unixTimestampSeconds(
            AppleContainerTimestampResolver.containerCreationDate(container)
        )

        return RESTContainerSummary(
            Id: DockerContainerID.hexId(for: container),
            Names: ["/" + container.id],
            Image: imageMetadata.displayReference,
            ImageID: imageMetadata.configDigest,
            ImageManifestDescriptor: nil,
            Command: ([container.configuration.initProcess.executable] + container.configuration.initProcess.arguments).joined(separator: " "),
            Created: createdTimestamp,
            Ports: ports,
            SizeRw: size,
            SizeRootFs: size,
            Labels: ContainerImageIdentity.dockerLabels(for: container),
            State: container.status.mobyState,
            Status: container.status.mobyState,
            HostConfig: ContainerHostConfig(NetworkMode: networkMode, Annotations: nil),
            NetworkSettings: ContainerNetworkSummary(Networks: networkSettings.isEmpty ? nil : networkSettings),
            Mounts: mounts,
            Platform: "linux"
        )
    }
}
