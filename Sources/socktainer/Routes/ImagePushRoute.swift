import Vapor

struct ImagePushRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "images", ":name", "push", use: ImagePushRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/{name}/push", req.method.rawValue)
    }
}
