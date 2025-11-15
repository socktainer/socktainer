import Vapor

struct PluginsNameSetRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name}/set", use: PluginsNameSetRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/set", req.method.rawValue)
    }
}
