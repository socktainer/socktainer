import Vapor

struct LibpodExecStartRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        // Podman posts `{"Detach":true}` without a Content-Type.
        let handler = LibpodAdapter.preparing(ExecRoute.startExec(client: client)) { req in
            LibpodAdapter.defaultToJSON(req)
            return req
        }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/exec/{id}/start", use: handler)
    }
}
