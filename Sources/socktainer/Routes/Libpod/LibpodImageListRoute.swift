import Vapor

struct LibpodImageListRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/json", use: ImageListRoute.handler(client: client))
    }
}
