import Vapor

struct VolumePruneRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "volumes", "prune", use: VolumePruneRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/volumes/prune", req.method.rawValue)
    }
}
