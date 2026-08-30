import Vapor

struct LibpodContainerPruneRoute: RouteCollection {
    let dockerRoute: ContainerPruneRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/prune", use: dockerRoute.handler)
    }
}
