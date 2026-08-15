import Vapor

struct TasksRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/tasks", use: TasksRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
