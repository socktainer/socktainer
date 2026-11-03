import Vapor

struct LibpodContainerKillRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/kill", use: ContainerKillRoute.handler(client: client))
    }
}
