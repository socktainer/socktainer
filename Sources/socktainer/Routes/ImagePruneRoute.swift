import Vapor

struct ImagePruneRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "images", "prune", use: ImagePruneRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/prune", req.method.rawValue)
    }
}
