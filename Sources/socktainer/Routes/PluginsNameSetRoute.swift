import Vapor

struct PluginsNameSetRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "plugins", ":name", "set", use: PluginsNameSetRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/set", req.method.string)
    }
}
