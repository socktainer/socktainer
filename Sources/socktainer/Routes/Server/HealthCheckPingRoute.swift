import Vapor

struct HealthCheckPingRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/_ping", use: HealthCheckPingRoute.handler(client: client))
        try routes.registerVersionedRoute(.HEAD, pattern: "/_ping", use: HealthCheckPingRoute.headHandler(client: client))
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

    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            try await client.ping()
            return buildResponse(includeBody: true)
        }
    }

    static func headHandler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            try await client.ping()
            return buildResponse(includeBody: false)
        }
    }
}
