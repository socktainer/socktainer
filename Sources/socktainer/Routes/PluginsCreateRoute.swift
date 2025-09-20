import Vapor

struct PluginsCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "plugins", "create", use: PluginsCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/create", req.method.string)
    }
}
