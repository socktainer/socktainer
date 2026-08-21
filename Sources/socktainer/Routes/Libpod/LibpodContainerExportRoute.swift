import Vapor

struct LibpodContainerExportRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/libpod/containers/{id}/export",
            use: ContainerExportRoute.handler(containerClient: containerClient, archiveClient: archiveClient)
        )
    }
}
