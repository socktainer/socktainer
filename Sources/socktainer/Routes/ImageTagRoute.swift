import Vapor

struct ImageTagRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "images", ":name", "tag", use: ImageTagRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/{name}/tag", req.method.rawValue)
    }
}
