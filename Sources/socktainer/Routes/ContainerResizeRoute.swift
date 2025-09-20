import Vapor

struct ContainerResizeRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "resize", use: ContainerResizeRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/resize", req.method.rawValue)
    }
}
