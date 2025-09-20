import Vapor

struct SecretsIdUpdateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "secrets", ":id", "update", use: SecretsIdUpdateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
