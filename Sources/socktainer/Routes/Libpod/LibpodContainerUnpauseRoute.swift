import Vapor

struct LibpodContainerUnpauseRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/unpause", use: ContainerUnpauseRoute.handler)
    }
}
