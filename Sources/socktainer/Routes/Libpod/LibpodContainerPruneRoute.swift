import Vapor

struct LibpodContainerPruneRoute: RouteCollection {
    let dockerRoute: ContainerPruneRoute

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(dockerRoute.handler) { body, _ in LibpodSchema.containerPruneReports(body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/prune", use: handler)
    }
}
