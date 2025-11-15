import Vapor

struct ContainerExportRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/export", use: ContainerExportRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/export", req.method.rawValue)
    }
}
