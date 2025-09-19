import Vapor

struct SwarmUnlockRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "swarm", "unlock", use: SwarmUnlockRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
