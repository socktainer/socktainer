import Vapor

struct LibpodContainerTopRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/top", use: ContainerTopRoute.handler)
    }
}
