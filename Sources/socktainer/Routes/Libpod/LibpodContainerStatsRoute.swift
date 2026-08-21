import Vapor

struct LibpodContainerStatsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/stats", use: ContainerStatsRoute.handler)
    }
}
