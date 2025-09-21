import Vapor

struct PluginsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "plugins", use: PluginsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins", req.method.rawValue)
    }
}
