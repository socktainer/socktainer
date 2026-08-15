import Vapor

struct HealthCheckPingRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/_ping", use: HealthCheckPingRoute.handler)
        try routes.registerVersionedRoute(.HEAD, pattern: "/_ping", use: HealthCheckPingRoute.headHandler)
    }
}

extension HealthCheckPingRoute {
    private static func buildResponse(includeBody: Bool) -> Response {
        let response = Response(status: .ok)
        if includeBody {
            response.body = .init(string: "OK")
        }
        response.headers.add(name: "Api-Version", value: "1.51")
        response.headers.add(name: "Builder-Version", value: "")
        response.headers.add(name: "Docker-Experimental", value: "false")
        response.headers.add(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
        response.headers.add(name: "Pragma", value: "no-cache")
        return response
    }

    static func handler(_ req: Request) async throws -> Response {
        buildResponse(includeBody: true)
    }

    static func headHandler(_ req: Request) async throws -> Response {
        buildResponse(includeBody: false)
    }
}
