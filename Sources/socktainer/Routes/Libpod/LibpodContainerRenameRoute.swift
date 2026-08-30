import Vapor

struct LibpodContainerRenameRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/rename", use: ContainerRenameRoute.handler)
    }
}
