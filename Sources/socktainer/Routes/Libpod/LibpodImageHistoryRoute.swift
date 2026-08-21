import ContainerPersistence
import Vapor

struct LibpodImageHistoryRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/{name:.*}/history", use: ImageHistoryRoute.handler(systemConfig: systemConfig))
    }
}
