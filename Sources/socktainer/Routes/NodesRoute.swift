import Vapor

struct NodesRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "nodes", use: NodesRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
