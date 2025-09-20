import Vapor

struct SystemDFRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "system", "df", use: SystemDFRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        NotImplemented.respond("/system/df", req.method.rawValue)
    }
}
