import ContainerizationOS
import Vapor

struct ContainerResizeRoute: RouteCollection {
    let client: ClientContainerService
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/resize", use: ContainerResizeRoute.resize(client: client))
    }

    static func resize(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let h = try? req.query.get(Int.self, at: "h"), h > 0 else {
                throw Abort(.badRequest, reason: "Missing or invalid height parameter")
            }

            guard let w = try? req.query.get(Int.self, at: "w"), w > 0 else {
                throw Abort(.badRequest, reason: "Missing or invalid width parameter")
            }

            guard let container = try await client.getContainer(id: containerId) else {
                throw Abort(.notFound, reason: "No such container: \(containerId)")
            }

            if let process = await ProcessRegistry.shared.get(id: container.id) {
                let size = Terminal.Size(width: UInt16(min(w, Int(UInt16.max))), height: UInt16(min(h, Int(UInt16.max))))
                try? await process.resize(size)
            }

            return Response(status: .ok)
        }
    }
}
