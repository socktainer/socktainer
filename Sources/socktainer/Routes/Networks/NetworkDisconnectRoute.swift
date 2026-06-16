import Vapor

struct NetworkDisconnectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/disconnect", use: NetworkDisconnectRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        Response(status: .ok)
    }
}
