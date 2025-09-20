import Vapor

struct ConfigsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "configs", use: ConfigsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
