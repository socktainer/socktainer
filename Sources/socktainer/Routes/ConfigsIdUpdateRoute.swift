import Vapor

struct ConfigsIdUpdateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "configs", ":id", "update", use: ConfigsIdUpdateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
