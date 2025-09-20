import Vapor

struct PluginsNameRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "plugins", ":name", use: PluginsNameRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}", req.method.string)
    }
}
