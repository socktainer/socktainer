import Vapor

struct HealthCheckPingRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/_ping", use: HealthCheckPingRoute.handler)
        try routes.registerVersionedRoute(.HEAD, pattern: "/_ping", use: HealthCheckPingRoute.headHandler)
    }
}

extension HealthCheckPingRoute {
    static func handler(_ req: Request) async throws -> Response {
        DockerPing.response(includeBody: true)
    }

    static func headHandler(_ req: Request) async throws -> Response {
        DockerPing.response(includeBody: false)
    }
}
