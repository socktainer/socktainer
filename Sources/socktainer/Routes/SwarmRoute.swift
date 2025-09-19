import Vapor

struct SwarmRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "swarm", use: SwarmRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
