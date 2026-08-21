import Vapor

struct LibpodContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/json", use: ContainerListRoute.handler(client: client))
    }
}
