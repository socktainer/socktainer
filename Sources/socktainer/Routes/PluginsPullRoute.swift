import Vapor

struct PluginsPullRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "plugins", "pull", use: PluginsPullRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/pull", req.method.rawValue)
    }
}
