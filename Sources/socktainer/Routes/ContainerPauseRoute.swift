import Vapor

struct ContainerPauseRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "pause", use: ContainerPauseRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/pause", req.method.rawValue)
    }
}
