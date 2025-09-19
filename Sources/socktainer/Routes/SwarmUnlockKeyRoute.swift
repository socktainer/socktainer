import Vapor

struct SwarmUnlockKeyRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "swarm", "unlockkey", use: SwarmUnlockKeyRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
