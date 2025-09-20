import Vapor

struct VolumeNameRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "volumes", ":name", use: VolumeNameRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/volumes/{name}", req.method.rawValue)
    }
}
