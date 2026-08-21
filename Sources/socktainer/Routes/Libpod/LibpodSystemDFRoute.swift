import Vapor

struct LibpodSystemDFRoute: RouteCollection {
    let dockerRoute: SystemDFRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/system/df", use: dockerRoute.handler)
    }
}
