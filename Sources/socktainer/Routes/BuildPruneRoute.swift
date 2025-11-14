import Vapor

struct BuildPruneRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/build/prune", use: BuildPruneRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/build/prune", req.method.rawValue)
    }
}
