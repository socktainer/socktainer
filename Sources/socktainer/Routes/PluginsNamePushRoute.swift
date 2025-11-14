import Vapor

struct PluginsNamePushRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name}/push", use: PluginsNamePushRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/plugins/{name}/push", req.method.rawValue)
    }
}
