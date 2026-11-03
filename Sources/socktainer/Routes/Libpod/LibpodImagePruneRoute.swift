import Vapor

struct LibpodImagePruneRoute: RouteCollection {
    let dockerRoute: ImagePruneRoute

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(dockerRoute.handler) { body, _ in LibpodSchema.imagePruneReports(body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/prune", use: handler)
    }
}
