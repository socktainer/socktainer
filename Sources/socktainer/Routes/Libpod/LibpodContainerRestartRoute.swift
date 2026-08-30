import Vapor

struct LibpodContainerRestartRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/restart", use: ContainerRestartRoute.handler(client: client))
    }
}
