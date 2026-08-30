import Vapor

struct LibpodContainerExistsRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/exists", use: LibpodContainerExistsRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            guard try await client.getContainer(id: id) != nil else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }
            return Response(status: .noContent)
        }
    }
}
