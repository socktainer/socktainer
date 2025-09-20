import Vapor

struct ContainerPruneRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", "prune", use: ContainerPruneRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/prune", req.method.rawValue)
    }
}
