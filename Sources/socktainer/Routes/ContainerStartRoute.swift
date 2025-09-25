import Vapor

struct ContainerStartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "start", use: ContainerStartRoute.handler(client: client))
        // also handle without version prefix
        routes.post("containers", ":id", "start", use: ContainerStartRoute.handler(client: client))
    }
}

struct ContainerStartQuery: Content {
    /// Override the key sequence for detaching a container
    let detachKeys: String?
}

extension ContainerStartRoute {
    // TODO: Update logic to parse stdin from request.
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in

            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerStartQuery.self)
            let detachKeys = query.detachKeys

            do {
                try await client.start(id: id, detachKeys: detachKeys)
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
