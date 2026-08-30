import Vapor

struct LibpodContainerStopRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/stop", use: ContainerStopRoute.handler(client: client))
    }
}
