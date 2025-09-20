import Vapor

struct ImagesGetRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "images", "get", use: ImagesGetRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/get", req.method.rawValue)
    }
}
