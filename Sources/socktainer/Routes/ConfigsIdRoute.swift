import Vapor

struct ConfigsIdRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "configs", ":id", use: ConfigsIdRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
