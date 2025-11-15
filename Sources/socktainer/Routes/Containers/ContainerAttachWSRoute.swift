import Vapor

struct ContainerAttachWSRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/attach/ws", use: ContainerAttachWSRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/attach/ws", req.method.rawValue)
    }
}
