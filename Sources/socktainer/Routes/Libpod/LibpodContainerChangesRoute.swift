import Vapor

struct LibpodContainerChangesRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/changes", use: ContainerChangesRoute.handler)
    }
}
