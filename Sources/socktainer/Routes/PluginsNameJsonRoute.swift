import Vapor

struct PluginsNameJsonRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/{name}/json", use: PluginsNameJsonRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/json", req.method.rawValue)
    }
}
