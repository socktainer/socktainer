import Vapor

struct LibpodContainerStartRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/start", use: ContainerStartRoute.handler(client: client))
    }
}
