import Vapor

struct NodesIdRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "nodes", ":id", use: NodesIdRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
