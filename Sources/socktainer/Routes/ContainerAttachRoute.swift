import Vapor

struct ContainerAttachRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "attach", use: ContainerAttachRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/attach", req.method.rawValue)
    }
}
