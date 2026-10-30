import Vapor

struct LibpodVolumeInspectRoute: RouteCollection {
    let dockerRoute: VolumeInspectRoute

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(dockerRoute.handler) { body, _ in LibpodSchema.volumeObject(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/volumes/{name}/json", use: handler)
    }
}
