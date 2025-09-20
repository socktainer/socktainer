import Vapor

struct ImageGetRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "images", ":name", "get", use: ImageGetRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/{name}/get", req.method.rawValue)
    }
}
