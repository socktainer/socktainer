import Vapor

/// `POST /libpod/exec/{id}/remove` — podman calls this after every attached `exec` to drop the
/// finished session (Docker-compat has no equivalent; its sessions are reaped on their own).
struct LibpodExecRemoveRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/exec/{id}/remove", use: LibpodExecRemoveRoute.handler)
    }

    static let handler: @Sendable (Request) async throws -> HTTPStatus = { req in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing exec session ID")
        }
        guard await ExecManager.shared.get(id: id) != nil else {
            throw Abort(.notFound, reason: "no such exec session: \(id)")
        }
        let force = (req.query["force"] as Bool?) ?? false
        if await ExecManager.shared.isRunning(id: id), !force {
            throw Abort(.conflict, reason: "exec session \(id) is still running")
        }
        await ExecManager.shared.remove(id: id)
        return .noContent
    }
}
