import Vapor

struct LibpodContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/wait", use: LibpodContainerWaitRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let conditionString = req.query["condition"] as String?
            let condition: ContainerWaitCondition

            if let conditionString = conditionString {
                condition = try Self.mapLibpodCondition(conditionString)
            } else {
                condition = ContainerWaitCondition.default
            }

            do {
                let waitResponse = try await client.wait(id: containerId, condition: condition)
                return try await waitResponse.encodeResponse(for: req)
            } catch ClientContainerError.notFound(let id) {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch {
                req.logger.error("Failed to wait for container \(containerId): \(error)")
                throw Abort(.internalServerError, reason: "Failed to wait for container")
            }
        }
    }

    /// Real podman's libpod `wait` endpoint (`condition=`, repeatable) uses the container's
    /// own lowercase status names ("configured", "created", "running", "paused", "exited",
    /// "stopped", "removing", ...), not Docker compat's `wait`-specific vocabulary
    /// (`ContainerWaitCondition`: "not-running", "next-exit", "removed", "healthy"). "removing"
    /// (in-progress removal) maps to the same `.removed` condition as Docker-compat's "removed"
    /// since this daemon has no distinct in-progress-removal state to block on. Only
    /// the first `condition` value is honored — real podman lets multiple be OR-matched,
    /// which would need genuine target-state polling this daemon's `client.wait` doesn't
    /// implement (it only supports "block until the container stops and report its exit
    /// code," matching Docker's own `wait`).
    private static func mapLibpodCondition(_ raw: String) throws -> ContainerWaitCondition {
        let first = raw.split(separator: ",").first.map(String.init) ?? raw
        switch first {
        case "stopped", "exited":
            return .notRunning
        case "removed", "removing":
            return .removed
        case "healthy":
            return .healthy
        case "running", "paused", "created", "configured":
            throw Abort(.notImplemented, reason: "waiting for condition '\(first)' is not supported; only 'stopped'/'exited' (and Docker-compat 'removed'/'healthy') are")
        default:
            throw Abort(.badRequest, reason: "Invalid wait condition: \(first)")
        }
    }
}
