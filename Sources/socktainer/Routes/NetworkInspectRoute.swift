import Vapor

struct NetworkInspectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "networks", ":id", use: NetworkInspectRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/networks/{id}", req.method.rawValue)
    }
}
