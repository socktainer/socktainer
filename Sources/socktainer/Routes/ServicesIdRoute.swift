import Vapor

struct ServicesIdRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "services", ":id", use: ServicesIdRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
