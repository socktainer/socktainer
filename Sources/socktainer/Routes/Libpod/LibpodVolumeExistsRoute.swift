import Vapor

struct LibpodVolumeExistsRoute: RouteCollection {
    let client: ClientVolumeService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/volumes/{name}/exists", use: LibpodVolumeExistsRoute.handler(client: client))
    }

    static func handler(client: ClientVolumeService) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing volume name")
            }
            do {
                _ = try await client.inspect(name: name)
                return Response(status: .noContent)
            } catch {
                guard VolumeNotFound.matches(error) else { throw error }
                throw Abort(.notFound, reason: "No such volume: \(name)")
            }
        }
    }
}
