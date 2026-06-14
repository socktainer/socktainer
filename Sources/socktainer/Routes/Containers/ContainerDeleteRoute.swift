import ContainerAPIClient
import Vapor

struct ContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .DELETE, pattern: "/containers/{id}", use: ContainerDeleteRoute.handler(client: client))
    }

}

extension ContainerDeleteRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            do {
                // Resolve the reference once — it may be a hex ID or a
                // truncated prefix — and reuse the snapshot for DNS
                // unregistration and the running check.
                let container = try await client.getContainer(id: id)

                // Cancel the healthcheck probe loop if one is running. Use the Apple
                // Container native ID (container?.id) to match the key stored at start time.
                if let healthManager = req.application.storage[HealthCheckManagerKey.self] {
                    await healthManager.stop(containerId: container?.id ?? id)
                }

                // Unregister DNS names before deletion
                if let container,
                    let dnsServer = req.application.storage[SocktainerDNSServerKey.self],
                    let namesLabel = container.configuration.labels["socktainer.dns.names"]
                {
                    for name in namesLabel.split(separator: ",").map(String.init) where !name.isEmpty {
                        dnsServer.unregister(hostname: name)
                    }
                }

                // if running, stop it first
                if let container, container.status == .running {
                    try await client.stop(id: id, signal: nil, timeout: nil)
                }
                try await client.delete(id: id)
            } catch ClientContainerError.notFound {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let event = DockerEvent.simpleEvent(id: id, type: "container", status: "remove")
            await broadcaster.broadcast(event)

            return .ok
        }
    }
}
