import Vapor

struct ServicesIdLogsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/services/{id}/logs", use: ServicesIdLogsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
