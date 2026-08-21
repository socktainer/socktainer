import Vapor

struct LibpodContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/json", use: ContainerInspectRoute.handler(client: client))
    }
}
