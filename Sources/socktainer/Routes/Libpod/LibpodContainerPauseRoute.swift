import Vapor

struct LibpodContainerPauseRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/pause", use: ContainerPauseRoute.handler)
    }
}
