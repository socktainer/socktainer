import Vapor

struct ConfigsCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/configs/create", use: ConfigsCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
