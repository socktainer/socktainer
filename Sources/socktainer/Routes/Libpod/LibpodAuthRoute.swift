import Vapor

struct LibpodAuthRoute: RouteCollection {
    let client: ClientRegistryService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/auth", use: AuthRoute.handler(client: client))
    }
}
