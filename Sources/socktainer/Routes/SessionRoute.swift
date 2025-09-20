import Vapor

struct SessionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "session", use: SessionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Interactive session")
    }
}
