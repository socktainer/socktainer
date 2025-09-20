import Vapor

struct ImageHistoryRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "images", ":name", "history", use: ImageHistoryRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/{name}/history", req.method.rawValue)
    }
}
