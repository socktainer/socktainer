import Vapor

struct LibpodNetworkInspectRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(
            NetworkInspectRoute.handler(client: client), prepare: LibpodAdapter.resolvingNetworkParameter("id", client: client)
        ) { body, _ in LibpodSchema.networkInspect(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/networks/{id}/json", use: handler)
    }
}
