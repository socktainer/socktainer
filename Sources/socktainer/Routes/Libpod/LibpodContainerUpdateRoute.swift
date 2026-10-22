import Vapor

struct LibpodContainerUpdateRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(
            ContainerUpdateRoute.handler(client: client), status: .created,
            prepare: { req in
                let body = try await LibpodAdapter.jsonObjectBody(of: req)
                let docker = LibpodSchema.dockerContainerUpdateBody(
                    fromLibpod: body, restartPolicy: req.query["restartPolicy"] as String?, restartRetries: req.query["restartRetries"] as Int?)
                return try LibpodAdapter.replacingBody(of: req, with: docker)
            }
        ) { _, req in
            ["Id": req.parameters.get("id") ?? ""]
        }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/update", use: handler)
    }
}
