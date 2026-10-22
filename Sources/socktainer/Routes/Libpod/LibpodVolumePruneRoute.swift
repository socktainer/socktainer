import Vapor

struct LibpodVolumePruneRoute: RouteCollection {
    let dockerRoute: VolumePruneRoute

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(dockerRoute.handler) { body, _ in LibpodSchema.volumePruneReports(body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/volumes/prune", use: handler)
    }
}
