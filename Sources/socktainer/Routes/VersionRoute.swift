import Vapor

struct VersionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("version", use: VersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/version", req.method.rawValue)
    }
}
