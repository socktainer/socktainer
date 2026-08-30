import Vapor

struct LibpodImagePruneRoute: RouteCollection {
    let dockerRoute: ImagePruneRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/prune", use: dockerRoute.handler)
    }
}
