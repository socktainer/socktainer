import Vapor

struct AuthRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "auth", use: AuthRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/auth", req.method.rawValue)
    }
}
