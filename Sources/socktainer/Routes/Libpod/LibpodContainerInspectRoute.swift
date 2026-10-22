import Vapor

struct LibpodContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(ContainerInspectRoute.handler(client: client)) { body, _ in LibpodSchema.containerInspect(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/json", use: handler)
    }
}
