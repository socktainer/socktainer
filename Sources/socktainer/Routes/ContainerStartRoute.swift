import Vapor

struct ContainerStartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "start", use: ContainerStartRoute.handler(client: client))
        // also handle without version prefix
        routes.post("containers", ":id", "start", use: ContainerStartRoute.handler(client: client))
    }
}

extension ContainerStartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            do {
                try await client.start(id: id, detach: true)
            } catch {
                req.logger.error("Failed to start container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to start container: \(error)")
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!

            let event = DockerEvent.simpleEvent(id: id, type: "container", status: "start")

            await broadcaster.broadcast(event)

            // should return 204 HTTP code
            return .noContent
        }
    }
}
