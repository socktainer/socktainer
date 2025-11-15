import Vapor

struct PluginsNameDisableRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name}/disable", use: PluginsNameDisableRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/disable", req.method.rawValue)
    }
}
