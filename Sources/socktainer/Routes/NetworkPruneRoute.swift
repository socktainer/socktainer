import Vapor

struct NetworkPruneRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "networks", "prune", use: NetworkPruneRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/networks/prune", req.method.rawValue)
    }
}
