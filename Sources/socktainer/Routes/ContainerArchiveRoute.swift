import Vapor

struct ContainerArchiveRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "archive", use: ContainerArchiveRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/archive", req.method.rawValue)
    }
}
