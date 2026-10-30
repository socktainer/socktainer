import Vapor

struct LibpodContainerRestartRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        // Podman sends the grace period as `timeout`; Docker-compat reads `t`.
        let handler = LibpodAdapter.preparing(ContainerRestartRoute.handler(client: client)) { req in
            LibpodAdapter.aliasQuery(req, libpod: "timeout", docker: "t")
            return req
        }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/restart", use: handler)
    }
}
