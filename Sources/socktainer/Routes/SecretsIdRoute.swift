import Vapor

struct SecretsIdRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "secrets", ":id", use: SecretsIdRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
