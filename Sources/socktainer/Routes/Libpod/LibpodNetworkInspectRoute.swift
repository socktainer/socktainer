import Vapor

struct LibpodNetworkInspectRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/networks/{id}/json", use: NetworkInspectRoute.handler(client: client))
    }
}
