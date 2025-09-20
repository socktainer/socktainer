import Vapor

struct ContainerRestartRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "restart", use: ContainerRestartRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/restart", req.method.rawValue)
    }
}
