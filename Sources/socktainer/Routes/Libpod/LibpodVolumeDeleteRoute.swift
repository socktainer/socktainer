import Vapor

struct LibpodVolumeDeleteRoute: RouteCollection {
    let dockerRoute: VolumeDeleteRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/volumes/{name}", use: dockerRoute.handler)
    }
}
