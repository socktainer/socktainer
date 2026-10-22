import Vapor

struct LibpodNetworkDeleteRoute: RouteCollection {
    let dockerRoute: NetworkDeleteRoute

    func boot(routes: RoutesBuilder) throws {
        // Docker answers 204; podman's `network.Remove` always decodes a `[]NetworkRmReport`.
        let handler = LibpodAdapter.reshaping(dockerRoute.handler) { _, req in
            LibpodSchema.networkRemoveReports(name: req.parameters.get("id") ?? "")
        }
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/networks/{id}", use: handler)
    }
}
