import Vapor

struct NetworkCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "networks", "create", use: NetworkCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/networks/create", req.method.rawValue)
    }
}
