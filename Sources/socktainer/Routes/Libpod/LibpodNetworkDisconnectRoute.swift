import Vapor

struct LibpodNetworkDisconnectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/{name}/disconnect", use: NetworkDisconnectRoute.handler)
    }
}
