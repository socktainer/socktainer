import Vapor

struct PluginsPrivilegesRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/privileges", use: PluginsPrivilegesRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/privileges", req.method.rawValue)
    }
}
