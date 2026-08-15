import Vapor

struct SwarmUpdateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/swarm/update", use: SwarmUpdateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
