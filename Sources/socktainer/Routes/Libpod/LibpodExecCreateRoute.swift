import Vapor

struct LibpodExecCreateRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/exec", use: ExecRoute.createExec(client: client))
    }
}
