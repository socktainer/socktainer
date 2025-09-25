import Vapor

struct ContainerRestartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "restart", use: ContainerRestartRoute.handler(client: client))
        // also handle without version prefix
        routes.post("containers", ":id", "restart", use: ContainerRestartRoute.handler(client: client))
    }
}

struct ContainerRestartQuery: Content {
    let signal: String?
    let t: Int?/// Number of seconds to wait before killing the container
}

extension ContainerRestartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerRestartQuery.self)
            let signal = query.signal
            let timeout = query.t

            do {
                try await client.restart(id: id, signal: signal, timeout: timeout)
            } catch ClientContainerError.notFound {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch {
                req.logger.error("Failed to restart container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to restart container: \(error)")
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!

            // Broadcast restart event (or both stop and start events)
            let restartEvent = DockerEvent.simpleEvent(id: id, type: "container", status: "restart")
            await broadcaster.broadcast(restartEvent)

            return .noContent
        }
    }
}
