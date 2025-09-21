import Vapor

struct ContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "json", use: ContainerInspectRoute.handler(client: client))
        // also handle without version prefix
        routes.get("containers", ":id", "json", use: ContainerInspectRoute.handler(client: client))

    }
}

extension ContainerInspectRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> RESTContainerInspect {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            let exposedPorts = Dictionary(
                uniqueKeysWithValues:
                    container.configuration.publishedPorts.map {
                        ("\($0.containerPort)/\($0.proto.rawValue)", EmptyObject())
                    }
            )

            let containerConfig: ContainerConfig = ContainerConfig(
                Image: container.configuration.image.reference,
                ExposedPorts: exposedPorts,
            )
            // add network settings
            let networkSettings: NetworkSettings = NetworkSettings(
                Ports: Dictionary(grouping: container.configuration.publishedPorts, by: { "\($0.hostPort)/\($0.proto.rawValue)" })
                    .mapValues { bindings in
                        bindings.map { PortBinding(HostIp: "\($0.hostAddress)", HostPort: "\($0.hostPort)") }
                    }
            )

            let hostConfig: HostConfig = HostConfig()

            let containerState: ContainerState = ContainerState(
                Status: container.status.rawValue,
                Running: container.status == .running,
                Paused: false,
                Restarting: false,
                OOMKilled: false,
                Dead: container.status == .stopped,
                Pid: 0,
                ExitCode: 0,
                Error: "",
                StartedAt: "",
                FinishedAt: ""
            )

            return RESTContainerInspect(
                Id: container.id,
                Names: ["/" + container.id],
                Image: container.configuration.image.reference,
                ImageID: container.configuration.image.digest,
                State: containerState,
                Config: containerConfig,
                HostConfig: hostConfig,
                NetworkSettings: networkSettings
            )
        }
    }
}
