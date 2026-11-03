import Vapor

struct LibpodImageSearchRoute: RouteCollection {
    let dockerRoute: ImageSearchRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/search", use: ImageSearchRoute.handler(searchProvider: dockerRoute.searchProvider))
    }
}
