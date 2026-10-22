import Vapor

struct LibpodImageListRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(ImageListRoute.handler(client: client)) { body, _ in LibpodSchema.imageList(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/json", use: handler)
    }
}
