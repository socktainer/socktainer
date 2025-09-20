import Vapor

struct ContainerStatsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "stats", use: ContainerStatsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/stats", req.method.rawValue)
    }
}
