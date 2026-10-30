import Vapor

struct LibpodContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/wait", use: LibpodContainerWaitRoute.handler(client: client))
    }

    /// Delegates to the Docker-compat wait — which also resolves a container that already exited
    /// before `/wait` arrived (the usual order for `podman run`) — then answers with the bare
    /// integer exit code podman's binding decodes, not Docker's `{"StatusCode": N}` object.
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        LibpodAdapter.reshaping(
            ContainerWaitRoute.handler(client: client),
            prepare: { req in
                if let raw = req.query["condition"] as String? {
                    LibpodAdapter.setQuery(req, "condition", to: try mapLibpodCondition(raw).rawValue)
                }
                return req
            }
        ) { body, _ in
            (body as? [String: Any])?["StatusCode"] ?? 0
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
    static func mapLibpodCondition(_ raw: String) throws -> ContainerWaitCondition {
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
