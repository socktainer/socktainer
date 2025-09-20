import Vapor

struct DistributionJsonRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "distribution", ":name", "json", use: DistributionJsonRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/distribution/{name}/json", req.method.rawValue)
    }
}
