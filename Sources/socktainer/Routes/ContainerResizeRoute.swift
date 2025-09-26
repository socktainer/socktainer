import Vapor

struct ContainerResizeRoute: RouteCollection {
    let client: ClientContainerService
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/resize", use: ContainerResizeRoute.resize(client: client))
    }

    // NOTE: This is stubbed as we are not using this endpoint to resize terminal size
    //       work needs to be done to inform the client on the new size
    static func resize(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let _ = try? req.query.get(Int.self, at: "h") else {
                throw Abort(.badRequest, reason: "Missing height parameter")
            }

            guard let _ = try? req.query.get(Int.self, at: "w") else {
                throw Abort(.badRequest, reason: "Missing width parameter")
            }

            guard let _ = try await client.getContainer(id: containerId) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            return Response(status: .ok)
        }
    }
}
