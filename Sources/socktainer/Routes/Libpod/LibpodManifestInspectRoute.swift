import ContainerPersistence
import Vapor

struct LibpodManifestInspectRoute: RouteCollection {
    let client: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/manifests/{name:.*}/json", use: LibpodManifestInspectRoute.handler(client: client))
    }

    static func handler(client: ClientManifestServiceProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing manifest list name")
            }
            do {
                let index = try await client.inspect(name: name)
                let data = try JSONEncoder().encode(index)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is ClientManifestError {
                throw Abort(.notFound, reason: "No such manifest list: \(name)")
            }
        }
    }
}
