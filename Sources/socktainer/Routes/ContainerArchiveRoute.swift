import Vapor

struct ContainerArchiveRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/archive", use: ContainerArchiveRoute.handler)
        try routes.registerVersionedRoute(.PUT, pattern: "/containers/{id:.*}/archive", use: ContainerArchiveRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/containers/{id}/archive", req.method.rawValue)
    }
}
