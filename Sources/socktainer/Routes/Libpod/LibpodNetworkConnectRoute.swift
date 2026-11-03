import Vapor

struct LibpodNetworkConnectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/{name}/connect", use: NetworkConnectRoute.handler)
    }
}
