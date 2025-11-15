import Vapor

struct PluginsNameUpgradeRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name}/upgrade", use: PluginsNameUpgradeRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/upgrade", req.method.rawValue)
    }
}
