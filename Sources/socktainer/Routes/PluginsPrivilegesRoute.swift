import Vapor

struct PluginsPrivilegesRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "plugins", "privileges", use: PluginsPrivilegesRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/privileges", req.method.rawValue)
    }
}
