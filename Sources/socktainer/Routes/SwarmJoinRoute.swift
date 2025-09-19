import Vapor

struct SwarmJoinRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "swarm", "join", use: SwarmJoinRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
