import Vapor

struct LibpodExecInspectRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/exec/{id}/json", use: ExecRoute.inspectExec(client: client))
    }
}
