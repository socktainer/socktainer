import Vapor

struct LibpodImageDeleteRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/images/{name:.*}", use: ImageDeleteRoute.handler(client: client))
    }
}
