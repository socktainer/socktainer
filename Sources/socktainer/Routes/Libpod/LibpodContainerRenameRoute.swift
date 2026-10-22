import Vapor

struct LibpodContainerRenameRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/rename", use: ContainerRenameRoute.handler(client: client))
    }
}
