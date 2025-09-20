import Vapor

struct ContainerUnpauseRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "unpause", use: ContainerUnpauseRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/unpause", req.method.rawValue)
    }
}
