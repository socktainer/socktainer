import Vapor

struct DistributionJsonRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/distribution/{name}/json", use: DistributionJsonRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/distribution/{name}/json", req.method.rawValue)
    }
}
