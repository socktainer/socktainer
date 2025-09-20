import Vapor

struct BuildRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "build", use: BuildRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/build", req.method.rawValue)
    }
}
