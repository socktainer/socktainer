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

struct SystemDFRoute: RouteCollection {
    let imageClient: ClientImageProtocol
    let containerClient: ClientContainerProtocol
    let volumeClient: ClientVolumeProtocol
    let builderClient: ClientBuilderProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/system/df", use: handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let query = try req.query.decode(SystemDFQuery.self)
        let requestedTypes = Set(query.type ?? [])
        let includeAll = requestedTypes.isEmpty

        async let images = imageClient.list(includeSystemImages: true)
        async let containers = containerClient.list(showAll: true, filters: [:])
        async let volumes = volumeClient.list(filters: nil, logger: req.logger)

        let (allImages, allContainers, allVolumes) = try await (images, containers, volumes)
        let usageByImageReference = Dictionary(grouping: allContainers, by: \.configuration.image.reference).mapValues(\.count)

        let imageSummaries: [RESTImageSummary]?
        if includeAll || requestedTypes.contains("image") {
            imageSummaries = try await Self.buildImageSummaries(images: allImages, usageByImageReference: usageByImageReference)
        } else {
            imageSummaries = nil
        }

        let containerSummaries: [RESTContainerSummary]?
        if includeAll || requestedTypes.contains("container") {
            containerSummaries = try await Self.buildContainerSummaries(containers: allContainers)
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
            let activeReferences = Set(allContainers.map(\.configuration.image.reference))
            let usage = try await ClientImage.calculateDiskUsage(activeReferences: activeReferences)
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
        usageByImageReference: [String: Int]
    ) async throws -> [RESTImageSummary] {
        try await withThrowingTaskGroup(of: RESTImageSummary.self) { group in
            for image in images {
                group.addTask {
                    let details: ImageDetail = try await image.details()
                    let manifests = try await image.index().manifests
                    var created = 0
                    var totalSize: Int64 = 0
                    var labels: [String: String] = [:]
                    var foundUsableManifest = false

                    for descriptor in manifests {
                        if descriptor.annotations?["vnd.docker.reference.type"] == "attestation-manifest" {
                            continue
                        }

                        let manifestSize: Int64
                        if let platform = descriptor.platform {
                            do {
                                let config = try await image.config(for: platform)
                                let manifest = try await image.manifest(for: platform)
                                manifestSize = descriptor.size + manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
                                totalSize += manifestSize
                                if !foundUsableManifest {
                                    created = Int(AppleContainerTimestampResolver.unixTimestampSeconds(config.created))
                                    labels = config.config?.labels ?? [:]
                                    foundUsableManifest = true
                                }
                                continue
                            } catch {
                            }
                        }

                        totalSize += descriptor.size
                    }

                    let repoTags = details.name.isEmpty ? [] : [details.name]
                    let repoDigests = image.reference.contains("@sha256:") ? [image.reference] : []
                    let containerCount = usageByImageReference[image.reference] ?? 0

                    return RESTImageSummary(
                        Id: image.digest,
                        ParentId: "",
                        RepoTags: repoTags,
                        RepoDigests: repoDigests,
                        Created: created,
                        Size: totalSize,
                        SharedSize: 0,
                        Labels: labels,
                        Containers: containerCount,
                        Manifests: nil,
                        Descriptor: nil
                    )
                }
            }

            var summaries: [RESTImageSummary] = []
            for try await summary in group {
                summaries.append(summary)
            }
            return summaries
        }
    }

    fileprivate static func buildContainerSummaries(containers: [ContainerSnapshot]) async throws -> [RESTContainerSummary] {
        let containerClient = ContainerClient()
        return try await withThrowingTaskGroup(of: RESTContainerSummary.self) { group in
            for container in containers {
                group.addTask {
                    let size = try await containerClient.diskUsage(id: container.id)
                    return containerSummary(from: container, size: Int64(clamping: size))
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
                        Labels: volume.Labels,
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

    fileprivate static func containerSummary(from container: ContainerSnapshot, size: Int64) -> RESTContainerSummary {
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
            uniqueKeysWithValues: container.networks.map { attachment in
                let endpoint = ContainerEndpointSettings(
                    IPAMConfig: nil,
                    Links: nil,
                    Aliases: nil,
                    NetworkID: attachment.network,
                    EndpointID: nil,
                    Gateway: stripSubnetFromIP(String(describing: attachment.ipv4Gateway)),
                    IPAddress: stripSubnetFromIP(String(describing: attachment.ipv4Address)),
                    IPPrefixLen: nil,
                    IPv6Gateway: nil,
                    GlobalIPv6Address: nil,
                    GlobalIPv6PrefixLen: nil,
                    MacAddress: nil,
                    DriverOpts: nil
                )
                return (attachment.network, endpoint)
            }
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
            Id: container.id,
            Names: ["/" + container.id],
            Image: container.configuration.image.reference,
            ImageID: container.configuration.image.digest,
            ImageManifestDescriptor: nil,
            Command: ([container.configuration.initProcess.executable] + container.configuration.initProcess.arguments).joined(separator: " "),
            Created: createdTimestamp,
            Ports: ports,
            SizeRw: size,
            SizeRootFs: size,
            Labels: container.configuration.labels,
            State: container.status.mobyState,
            Status: container.status.mobyState,
            HostConfig: ContainerHostConfig(NetworkMode: networkMode, Annotations: nil),
            NetworkSettings: ContainerNetworkSummary(Networks: networkSettings.isEmpty ? nil : networkSettings),
            Mounts: mounts,
            Platform: "linux"
        )
    }
}
