import Vapor

struct PluginsNameEnableRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name}/enable", use: PluginsNameEnableRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/enable", req.method.rawValue)
    }
}
