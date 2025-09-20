import Vapor

struct PluginsNameJsonRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "plugins", ":name", "json", use: PluginsNameJsonRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/json", req.method.string)
    }
}
