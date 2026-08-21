import Vapor

struct LibpodManifestExistsRoute: RouteCollection {
    let client: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/manifests/{name:.*}/exists", use: LibpodManifestExistsRoute.handler(client: client))
    }

    static func handler(client: ClientManifestServiceProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing manifest list name")
            }
            guard try await client.exists(name: name) else {
                throw Abort(.notFound, reason: "No such manifest list: \(name)")
            }
            return Response(status: .noContent)
        }
    }
}
