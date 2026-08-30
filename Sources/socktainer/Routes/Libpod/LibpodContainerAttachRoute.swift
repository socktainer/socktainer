import Vapor

struct LibpodContainerAttachRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/attach", use: ContainerAttachRoute.handler(client: client))
    }
}
