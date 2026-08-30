import Vapor

struct LibpodNetworkExistsRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/networks/{name}/exists", use: LibpodNetworkExistsRoute.handler(client: client))
    }

    static func handler(client: ClientNetworkProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing network name")
            }
            guard try await client.getNetwork(id: name, logger: req.logger) != nil else {
                throw Abort(.notFound, reason: "No such network: \(name)")
            }
            return Response(status: .noContent)
        }
    }
}
