import Vapor

struct ContainerUpdateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "update", use: ContainerUpdateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/update", req.method.rawValue)
    }
}
