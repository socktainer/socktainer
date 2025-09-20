import Vapor

struct ContainerTopRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "top", use: ContainerTopRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/top", req.method.rawValue)
    }
}
