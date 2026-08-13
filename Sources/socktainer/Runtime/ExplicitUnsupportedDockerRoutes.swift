import Vapor

/// Keeps the advertised Docker API surface explicit while the persistent
/// containerd runtime is still alpha. Known endpoints must not fall through to
/// a generic router 404, which clients can misinterpret as a version mismatch.
struct ExplicitUnsupportedDockerRoutes: RouteCollection {
    private struct Endpoint {
        let method: HTTPMethod
        let pattern: String
    }

    private static let endpoints = [
        Endpoint(method: .GET, pattern: "/info"),
        Endpoint(method: .GET, pattern: "/system/df"),
        Endpoint(method: .POST, pattern: "/containers/prune"),
        Endpoint(method: .POST, pattern: "/containers/{id}/restart"),
        Endpoint(method: .POST, pattern: "/containers/{id}/pause"),
        Endpoint(method: .POST, pattern: "/containers/{id}/unpause"),
        Endpoint(method: .POST, pattern: "/containers/{id}/rename"),
        Endpoint(method: .POST, pattern: "/containers/{id}/resize"),
        Endpoint(method: .POST, pattern: "/containers/{id}/update"),
        Endpoint(method: .GET, pattern: "/containers/{id}/stats"),
        Endpoint(method: .GET, pattern: "/containers/{id}/top"),
        Endpoint(method: .GET, pattern: "/containers/{id}/changes"),
        Endpoint(method: .GET, pattern: "/containers/{id}/export"),
        Endpoint(method: .GET, pattern: "/containers/{id}/archive"),
        Endpoint(method: .HEAD, pattern: "/containers/{id}/archive"),
        Endpoint(method: .PUT, pattern: "/containers/{id}/archive"),
        Endpoint(method: .GET, pattern: "/containers/{id}/attach/ws"),
        Endpoint(method: .POST, pattern: "/exec/{id}/resize"),
        Endpoint(method: .GET, pattern: "/images/{name:.*}/history"),
        Endpoint(method: .POST, pattern: "/images/{name:.*}/push"),
        Endpoint(method: .GET, pattern: "/images/search"),
        Endpoint(method: .GET, pattern: "/images/get"),
        Endpoint(method: .GET, pattern: "/images/{name:.*}/get"),
        Endpoint(method: .POST, pattern: "/images/load"),
        Endpoint(method: .POST, pattern: "/build"),
        Endpoint(method: .POST, pattern: "/build/prune"),
        Endpoint(method: .POST, pattern: "/commit"),
        Endpoint(method: .POST, pattern: "/networks/create"),
        Endpoint(method: .GET, pattern: "/networks"),
        Endpoint(method: .GET, pattern: "/networks/{id}"),
        Endpoint(method: .DELETE, pattern: "/networks/{id}"),
        Endpoint(method: .POST, pattern: "/networks/prune"),
        Endpoint(method: .POST, pattern: "/networks/{id}/connect"),
        Endpoint(method: .POST, pattern: "/networks/{id}/disconnect"),
        Endpoint(method: .GET, pattern: "/distribution/{name:.*}/json"),
    ]

    func boot(routes: RoutesBuilder) throws {
        for endpoint in Self.endpoints {
            try routes.registerVersionedRoute(
                endpoint.method,
                pattern: endpoint.pattern,
                use: unsupported
            )
        }
    }

    private func unsupported(_ request: Request) async throws -> Response {
        throw Abort(
            .notImplemented,
            reason: "Docker endpoint \(request.method.rawValue) \(request.url.path) is not implemented by the persistent runtime"
        )
    }
}
