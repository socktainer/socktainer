import Vapor

struct LibpodVolumePruneRoute: RouteCollection {
    let dockerRoute: VolumePruneRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/volumes/prune", use: dockerRoute.handler)
    }
}
