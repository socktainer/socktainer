import Vapor

struct HealthCheckPingRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/_ping", use: HealthCheckPingRoute.handler(client: client))
    }
}

extension HealthCheckPingRoute {
    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            try await client.ping()

            let response = Response(status: .ok)
            response.body = .init(string: "OK")

            // add headers
            response.headers.add(name: "Api-Version", value: "1.51")
            // not supported
            response.headers.add(name: "Builder-Version", value: "")
            response.headers.add(name: "Docker-Experimental", value: "false")

            // Cache control
            response.headers.add(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
            // Pragma: no-cache
            response.headers.add(name: "Pragma", value: "no-cache")

            return response

        }
    }
}
