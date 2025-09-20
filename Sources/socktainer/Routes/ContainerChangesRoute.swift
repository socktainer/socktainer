import Vapor

struct ContainerChangesRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "changes", use: ContainerChangesRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/changes", req.method.rawValue)
    }
}
