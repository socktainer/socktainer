import Vapor

struct SwarmLeaveRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "swarm", "leave", use: SwarmLeaveRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
