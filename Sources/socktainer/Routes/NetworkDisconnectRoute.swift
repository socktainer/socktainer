import Vapor

struct NetworkDisconnectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "networks", ":id", "disconnect", use: NetworkDisconnectRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/networks/{id}/disconnect", req.method.rawValue)
    }
}
