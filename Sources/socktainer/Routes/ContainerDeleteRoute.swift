import Vapor

struct ContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.delete(":version", "containers", ":id", use: ContainerDeleteRoute.handler(client: client))
        // also handle without version prefix
        routes.delete("containers", ":id", use: ContainerDeleteRoute.handler(client: client))

    }

}

extension ContainerDeleteRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            // if running, stop it first
            if let container = try await client.getContainer(id: id),
                container.status == .running
            {
                try await client.stop(id: id)
            }
            try await client.delete(id: id)

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!

            let event = DockerEvent.simpleEvent(id: id, type: "container", status: "remove")

            await broadcaster.broadcast(event)

            return .ok

        }
    }
}
