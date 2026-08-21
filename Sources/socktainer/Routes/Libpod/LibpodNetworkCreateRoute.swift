import Vapor

struct LibpodNetworkCreateRoute: RouteCollection {
    let dockerRoute: NetworkCreateRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/create", use: dockerRoute.handler)
    }
}
