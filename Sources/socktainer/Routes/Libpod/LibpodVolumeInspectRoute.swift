import Vapor

struct LibpodVolumeInspectRoute: RouteCollection {
    let dockerRoute: VolumeInspectRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/volumes/{name}/json", use: dockerRoute.handler)
    }
}
