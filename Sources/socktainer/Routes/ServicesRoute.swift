import Vapor

struct ServicesRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "services", use: ServicesRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
