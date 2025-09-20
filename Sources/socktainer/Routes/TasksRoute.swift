import Vapor

struct TasksRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "tasks", use: TasksRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
