import Vapor

struct LibpodPingRoute: RouteCollection {
    let client: ClientHealthCheckProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/_ping", use: HealthCheckPingRoute.handler(client: client))
        try routes.registerVersionedRoute(.HEAD, pattern: "/libpod/_ping", use: HealthCheckPingRoute.headHandler(client: client))
    }
}
