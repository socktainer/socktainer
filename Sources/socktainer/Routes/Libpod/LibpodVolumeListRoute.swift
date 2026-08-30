import Vapor

struct LibpodVolumeListRoute: RouteCollection {
    let dockerRoute: VolumeListRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/volumes/json", use: dockerRoute.handler)
    }
}
