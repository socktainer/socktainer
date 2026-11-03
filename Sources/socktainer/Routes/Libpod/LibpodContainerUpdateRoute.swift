import Vapor

struct LibpodContainerUpdateRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        let client = self.client
        let handler = LibpodAdapter.reshaping(
            ContainerUpdateRoute.handler(client: client), status: .created,
            prepare: { req in
                let body = try await LibpodAdapter.jsonObjectBody(of: req)
                // Docker's update has no environment; refuse rather than apply the rest and
                // report success with the environment change silently dropped.
                for key in ["Env", "UnsetEnv"] where !((body[key] as? [Any]) ?? []).isEmpty {
                    throw Abort(.badRequest, reason: "updating a container's environment (\(key)) is not supported")
                }
                let docker = LibpodSchema.dockerContainerUpdateBody(
                    fromLibpod: body, restartPolicy: req.query["restartPolicy"] as String?, restartRetries: req.query["restartRetries"] as Int?)
                return try LibpodAdapter.replacingBody(of: req, with: docker)
            }
        ) { _, req in
            // podman answers with the container's full ID as a bare JSON string.
            let reference = req.parameters.get("id") ?? ""
            guard let container = try await client.getContainer(id: reference) else { return reference }
            return DockerContainerID.hexId(for: container)
        }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/update", use: handler)
    }
}
