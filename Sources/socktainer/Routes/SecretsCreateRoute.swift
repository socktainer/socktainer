import Vapor

struct SecretsCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "secrets", "create", use: SecretsCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
