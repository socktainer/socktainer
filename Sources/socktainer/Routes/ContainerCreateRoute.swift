import Vapor

struct ContainerCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", "create", use: ContainerCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/create", req.method.rawValue)
    }
}
