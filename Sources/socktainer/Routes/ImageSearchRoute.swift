import Vapor

struct ImageSearchRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "images", "search", use: ImageSearchRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/search", req.method.rawValue)
    }
}
