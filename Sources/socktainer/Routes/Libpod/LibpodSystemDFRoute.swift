import Vapor

struct LibpodSystemDFRoute: RouteCollection {
    let dockerRoute: SystemDFRoute

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(dockerRoute.handler) { body, _ in LibpodSchema.systemDF(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/system/df", use: handler)
    }
}
