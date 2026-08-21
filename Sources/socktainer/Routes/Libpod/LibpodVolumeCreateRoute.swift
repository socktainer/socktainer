import Vapor

struct LibpodVolumeCreateRoute: RouteCollection {
    let dockerRoute: VolumeCreateRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/volumes/create", use: dockerRoute.handler)
    }
}
