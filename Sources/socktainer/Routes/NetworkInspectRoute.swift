import Vapor

struct RESTNetworkInspectQuery: Content {
    let verbose: Bool?
    let scope: Bool
}

struct NetworkInspectRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "networks", ":id", use: NetworkInspectRoute.handler(client: client))
        // Optionally, add route without version prefix
        routes.get("networks", ":id", use: NetworkInspectRoute.handler(client: client))
    }

    static func handler(client: ClientNetworkProtocol) -> @Sendable (Request) async throws -> RESTNetworkSummary {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing network ID")
            }
            let logger = req.logger
            guard let network = try await client.getNetwork(id: id, logger: logger) else {
                throw Abort(.notFound, reason: "Network not found")
            }
            return network
        }
    }
}
