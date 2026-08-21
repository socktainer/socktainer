import Vapor

struct LibpodContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/containers/{id}", use: ContainerDeleteRoute.handler(client: client))
    }
}
