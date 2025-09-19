import Vapor

struct InfoRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "info", use: InfoRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/info", "GET")
    }
}
