import Vapor

struct LibpodImagesGetRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/get", use: ImagesGetRoute.handlerMultiple(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/{name:.*}/get", use: ImagesGetRoute.handlerSingle(client: client))
    }
}
