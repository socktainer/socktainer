import ContainerPersistence
import Vapor

struct LibpodImageInspectRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        let handler = LibpodAdapter.reshaping(ImageInspectRoute.handler(systemConfig: systemConfig)) { body, _ in LibpodSchema.imageInspect(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/{name:.*}/json", use: handler)
    }
}
