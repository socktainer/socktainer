import Vapor

struct ImagesLoadRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "images", "load", use: ImagesLoadRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/load", req.method.rawValue)
    }
}
