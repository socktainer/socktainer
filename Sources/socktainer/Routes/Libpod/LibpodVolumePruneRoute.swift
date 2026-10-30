import Vapor

struct LibpodVolumePruneRoute: RouteCollection {
    let dockerRoute: VolumePruneRoute

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(
            dockerRoute.handler,
            prepare: { req in
                LibpodAdapter.setQuery(req, "filters", to: try LibpodSchema.volumePruneFilters(req.query["filters"] as String?))
                return req
            }
        ) { body, _ in LibpodSchema.volumePruneReports(body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/volumes/prune", use: handler)
    }
}
