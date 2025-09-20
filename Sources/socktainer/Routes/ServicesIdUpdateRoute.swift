import Vapor

struct ServicesIdUpdateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "services", ":id", "update", use: ServicesIdUpdateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
