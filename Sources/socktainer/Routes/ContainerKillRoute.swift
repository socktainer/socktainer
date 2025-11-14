import ContainerClient
import Vapor

struct ContainerKillQuery: Content {
    let signal: String?
}

struct ContainerKillRoute: RouteCollection {
    let client: ClientContainerService
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/kill", use: ContainerKillRoute.handler(client: client))
    }
}

extension ContainerKillRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            let query = try req.query.decode(ContainerKillQuery.self)

            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Container ID is required")
            }

            let signal = query.signal ?? nil

            do {
                try await client.kill(id: containerId, signal: signal)
                return Response(status: .noContent)
            } catch ClientContainerError.notFound {
                return Response(status: .notFound, body: .init(string: "container \(containerId) not found"))
            } catch ClientContainerError.notRunning {
                return Response(status: .conflict, body: .init(string: "container \(containerId) is not running"))
            } catch {
                req.logger.error("Failed to kill container \(containerId): \(error)")
                return Response(status: .internalServerError, body: .init(string: "Failed to kill container: \(error)"))
            }
        }
    }
}
