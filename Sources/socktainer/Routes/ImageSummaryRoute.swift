import Vapor

struct ImageSummaryRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "images", ":name", "json", use: ImageSummaryRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/{name}/json", req.method.rawValue)
    }
}
