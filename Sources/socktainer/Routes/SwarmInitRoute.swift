import Vapor

struct SwarmInitRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "swarm", "init", use: SwarmInitRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
