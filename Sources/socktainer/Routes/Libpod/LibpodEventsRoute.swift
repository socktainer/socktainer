import Vapor

struct LibpodEventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/events", use: EventsRoute.handler(client: client))
    }
}
