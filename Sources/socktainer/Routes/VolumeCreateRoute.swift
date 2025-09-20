import Vapor

struct VolumeCreateRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "volumes", "create", use: VolumeCreateRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/volumes/create", req.method.rawValue)
    }
}
