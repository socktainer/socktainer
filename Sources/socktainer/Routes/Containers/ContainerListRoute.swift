import ContainerAPIClient
import ContainerResource
import Vapor

struct ContainerListQuery: Content {
    var all: Bool?
    var filters: String?
}

struct ContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/json", use: ContainerListRoute.handler(client: client))
    }
}

extension ContainerListRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> [RESTContainerSummary] {
        { req in
            let query = try req.query.decode(ContainerListQuery.self)
            let showAll = query.all ?? false

            let parsedFilters = try DockerContainerFilterUtility.parseContainerFilters(filtersParam: query.filters, logger: req.logger)
            let containers = try await client.list(showAll: showAll, filters: parsedFilters)

            // Apply health filter here using the real HealthCheckManager state.
            // ClientContainerService skips the health filter to avoid a stale heuristic.
            let healthFilter = parsedFilters["health"]
            let healthManager = req.application.storage[HealthCheckManagerKey.self]
            var filteredContainers: [ContainerSnapshot] = []
            for container in containers {
                if let healthFilter, !healthFilter.isEmpty {
                    // Containers with no healthcheck configured report "none"
                    let status =
                        await healthManager?.currentHealth(for: container.id)?.Status ?? "none"
                    guard healthFilter.contains(status) else { continue }
                }
                filteredContainers.append(container)
            }

            var summaries: [RESTContainerSummary] = []
            for container in filteredContainers {
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
                    case .block(_, _, _):
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
                    let mode = isReadOnly ? "ro" : "rw"

                    return ContainerMountPoint(
                        type: mountType,
                        name: mountName,
                        source: mount.source,
                        destination: mount.destination,
                        driver: driver,
                        mode: mode,
                        rw: !isReadOnly,
                        propagation: ""
                    )
                }

                let createdTimestamp = AppleContainerTimestampResolver.unixTimestampSeconds(
                    AppleContainerTimestampResolver.containerCreationDate(container)
                )

                let mobyState = container.status.mobyState
                // Build human-readable status matching Docker's "Up X seconds/minutes/hours" format
                let baseStatus: String
                switch container.status {
                case .running:
                    if let started = container.startedDate {
                        baseStatus = "Up \(Self.humanReadableAge(since: started))"
                    } else {
                        baseStatus = "Up"
                    }
                case .stopped:
                    baseStatus = "Exited"
                default:
                    baseStatus = mobyState
                }
                let statusStr: String
                if let health = await req.application.storage[HealthCheckManagerKey.self]?.currentHealth(
                    for: container.id)
                {
                    // Match Docker's format: "Up 2 minutes (healthy)" not "(health: healthy)"
                    statusStr = "\(baseStatus) (\(health.Status))"
                } else {
                    statusStr = baseStatus
                }

                let summary = RESTContainerSummary(
                    Id: DockerContainerID.hexId(for: container),
                    Names: ["/" + container.id],
                    Image: container.configuration.image.reference,
                    ImageID: container.configuration.image.digest,
                    ImageManifestDescriptor: nil,
                    Command: ([container.configuration.initProcess.executable] + container.configuration.initProcess.arguments).joined(separator: " "),
                    Created: createdTimestamp,
                    Ports: ports,
                    SizeRw: nil,  // there is no mechanism to retrieve this value from apple container
                    SizeRootFs: nil,  // there is no mechanism to retrieve this value from apple container
                    Labels: container.configuration.labels,
                    State: mobyState,
                    Status: statusStr,
                    HostConfig: ContainerHostConfig(NetworkMode: networkMode, Annotations: nil),
                    NetworkSettings: ContainerNetworkSummary(Networks: networkSettings.isEmpty ? nil : networkSettings),
                    Mounts: mounts,
                    Platform: "linux"  // Apple containers always run linux platform
                )
                summaries.append(summary)
            }
            return summaries
        }
    }

    /// Returns a human-readable duration string matching Docker's "Up X seconds/minutes/hours/days" format.
    static func humanReadableAge(since date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds) second\(seconds == 1 ? "" : "s")" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }
}
