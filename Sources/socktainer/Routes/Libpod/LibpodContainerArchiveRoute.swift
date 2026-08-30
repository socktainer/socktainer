import Vapor

struct LibpodContainerArchiveRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/libpod/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.getHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
        try routes.registerVersionedRoute(
            .PUT,
            pattern: "/libpod/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.putHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
        try routes.registerVersionedRoute(
            .HEAD,
            pattern: "/libpod/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.headHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
    }
}
