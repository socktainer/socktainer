import Vapor

struct LibpodExecStartRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/exec/{id}/start", use: ExecRoute.startExec(client: client))
    }
}
