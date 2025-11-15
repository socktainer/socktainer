import Vapor

struct ImageHistoryRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/history", use: ImageHistoryRoute.handler)
    }

}

extension ImageHistoryRoute {
    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/images/{name}/history", req.method.rawValue)
    }
}
