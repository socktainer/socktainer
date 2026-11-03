import ContainerPersistence
import Vapor

struct LibpodImageTagRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/{name:.*}/tag") { [systemConfig] req in
            try await ImageTagRoute.handler(req, systemConfig: systemConfig)
        }
    }
}
