import Vapor

struct ServicesCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/services/create", use: ServicesCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
