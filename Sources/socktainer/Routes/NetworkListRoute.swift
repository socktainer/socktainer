import Vapor

struct NetworkListRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "networks", use: NetworkListRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/networks", req.method.rawValue)
    }
}
