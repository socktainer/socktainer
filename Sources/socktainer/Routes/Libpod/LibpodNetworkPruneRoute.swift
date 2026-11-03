import Vapor

struct LibpodNetworkPruneRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(NetworkPruneRoute.handler) { body, _ in try Self.reports(from: body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/prune", use: handler)
    }

    /// podman decodes each report's `Error` into a Go `error`, which accepts only null, so failed
    /// removals cannot ride along in the reports; they fail the request instead, as a failing
    /// prune does on podman's own server.
    static func reports(from body: Any?) throws -> Any {
        let errors = (body as? [String: Any])?["Errors"] as? [String: Any] ?? [:]
        guard errors.isEmpty else {
            let details = errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            throw Abort(.internalServerError, reason: "failed to prune networks: \(details)")
        }
        return LibpodSchema.networkPruneReports(body)
    }
}
