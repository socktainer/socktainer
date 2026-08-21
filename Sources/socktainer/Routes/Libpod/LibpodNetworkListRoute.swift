import Vapor

struct LibpodNetworkListRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/networks/json", use: NetworkListRoute.handler)
    }
}
