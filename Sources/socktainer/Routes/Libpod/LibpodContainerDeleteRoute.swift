import Vapor

struct LibpodContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        // Docker answers 204; podman's `containers.Remove` decodes a `[]RmReport` even on success.
        let reshaped = LibpodAdapter.reshaping(ContainerDeleteRoute.handler(client: client), prepare: Self.prepare) { _, req in
            LibpodSchema.containerRemoveReports(id: req.parameters.get("id") ?? "")
        }
        // `ignore=true` (podman's own cleanup of a `--rm` container the server already reaped) turns
        // "no such container" into an empty success.
        let handler: LibpodAdapter.Handler = { req in
            do {
                return try await reshaped(req)
            } catch let error as AbortError where error.status == .notFound && ((req.query["ignore"] as Bool?) ?? false) {
                return try LibpodAdapter.jsonResponse([Any]())
            }
        }
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/containers/{id}", use: handler)
    }

    /// `podman rm -v` sends `volumes=true`; Docker-compat reads `v`.
    @Sendable static func prepare(_ req: Request) -> Request {
        LibpodAdapter.aliasQuery(req, libpod: "volumes", docker: "v")
        return req
    }
}
