import Vapor

struct LibpodContainerLogsRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/logs", use: ContainerLogsRoute.handler(client: client))
    }
}
