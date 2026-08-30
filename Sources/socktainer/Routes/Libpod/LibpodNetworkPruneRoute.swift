import Vapor

struct LibpodNetworkPruneRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/prune", use: NetworkPruneRoute.handler)
    }
}
