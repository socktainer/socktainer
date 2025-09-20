import Vapor

struct CommitRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "commit", use: CommitRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/commit", req.method.rawValue)
    }
}
