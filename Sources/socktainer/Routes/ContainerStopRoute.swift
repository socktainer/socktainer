import Vapor

struct ContainerStopRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "stop", use: ContainerStopRoute.handler(client: client))
        // also handle without version prefix
        routes.post("containers", ":id", "stop", use: ContainerStopRoute.handler(client: client))

    }
}

struct ContainerStopQuery: Content {
    let signal: String?
    let t: Int?/// Number of seconds to wait before stopping the container
}

extension ContainerStopRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerStopQuery.self)
            let signal = query.signal
            let timeout = query.t

            try await client.stop(id: id, signal: signal, timeout: timeout)

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!

            let event = DockerEvent.simpleEvent(id: id, type: "container", status: "stop")

            await broadcaster.broadcast(event)

            return .noContent
        }
    }
}
