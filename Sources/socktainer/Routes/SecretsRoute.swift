import Vapor

struct SecretsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "secrets", use: SecretsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
