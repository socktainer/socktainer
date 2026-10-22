import Vapor

struct LibpodNetworkListRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(NetworkListRoute.handler) { body, _ in LibpodSchema.networkList(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/networks/json", use: handler)
    }
}
