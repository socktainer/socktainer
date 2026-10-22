import Vapor

struct LibpodContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        // Docker answers 204; podman's `containers.Remove` decodes a `[]RmReport` even on success.
        let handler = LibpodAdapter.reshaping(ContainerDeleteRoute.handler(client: client)) { _, req in
            LibpodSchema.containerRemoveReports(id: req.parameters.get("id") ?? "")
        }
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/containers/{id}", use: handler)
    }
}
