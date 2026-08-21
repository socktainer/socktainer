import Vapor

struct LibpodNetworkDeleteRoute: RouteCollection {
    let dockerRoute: NetworkDeleteRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/networks/{id}", use: dockerRoute.handler)
    }
}
