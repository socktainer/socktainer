import Vapor

struct ContainerRenameRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "rename", use: ContainerRenameRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/rename", req.method.rawValue)
    }
}
