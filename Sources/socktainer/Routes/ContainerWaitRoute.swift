import Vapor

struct ContainerWaitRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "wait", use: ContainerWaitRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/wait", req.method.rawValue)
    }
}
