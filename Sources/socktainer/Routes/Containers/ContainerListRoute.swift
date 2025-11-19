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

            return containers.map { container in
                let ports = container.configuration.publishedPorts.map { port in
                    ContainerPort(
                        IP: port.hostAddress,
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
                            Gateway: stripSubnetFromIP(attachment.gateway),
                            IPAddress: stripSubnetFromIP(attachment.address),
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

                let createdTimestamp: Int64
                if let timestampStr = container.configuration.labels["io.github.socktainer.creation-timestamp"],
                    let timestamp = Double(timestampStr)
                {
                    createdTimestamp = Int64(timestamp)
                } else {
                    createdTimestamp = 0
                }

                return RESTContainerSummary(
                    Id: container.id,
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
                    State: container.status.mobyState,
                    Status: container.status.mobyState,
                    HostConfig: ContainerHostConfig(NetworkMode: networkMode, Annotations: nil),
                    NetworkSettings: ContainerNetworkSummary(Networks: networkSettings.isEmpty ? nil : networkSettings),
                    Mounts: mounts,
                    Platform: "linux"  // Apple containers always run linux platform
                )
            }
        }
    }
}
