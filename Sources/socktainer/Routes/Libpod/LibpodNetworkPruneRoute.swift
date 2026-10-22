import Vapor

struct LibpodNetworkPruneRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(NetworkPruneRoute.handler) { body, _ in LibpodSchema.networkPruneReports(body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/prune", use: handler)
    }
}
