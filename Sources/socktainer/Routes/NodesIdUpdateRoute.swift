import Vapor

struct NodesIdUpdateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "nodes", ":id", "update", use: NodesIdUpdateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
