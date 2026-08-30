import Vapor

struct LibpodContainerUpdateRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/update", use: ContainerUpdateRoute.handler(client: client))
    }
}
