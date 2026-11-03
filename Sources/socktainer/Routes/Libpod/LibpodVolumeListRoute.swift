import Vapor

struct LibpodVolumeListRoute: RouteCollection {
    let dockerRoute: VolumeListRoute

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(dockerRoute.handler) { body, _ in LibpodSchema.volumeList(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/volumes/json", use: handler)
    }
}
