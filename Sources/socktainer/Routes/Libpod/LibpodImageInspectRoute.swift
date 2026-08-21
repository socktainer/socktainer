import ContainerPersistence
import Vapor

struct LibpodImageInspectRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/{name:.*}/json", use: ImageInspectRoute.handler(systemConfig: systemConfig))
    }
}
