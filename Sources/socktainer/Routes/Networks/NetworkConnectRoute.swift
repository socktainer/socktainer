import Vapor

struct NetworkConnectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/connect", use: NetworkConnectRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/networks/{id}/connect", req.method.rawValue)
    }
}
