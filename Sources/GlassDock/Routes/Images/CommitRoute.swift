import Vapor

struct CommitRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/commit", use: CommitRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/commit", req.method.rawValue)
    }
}
