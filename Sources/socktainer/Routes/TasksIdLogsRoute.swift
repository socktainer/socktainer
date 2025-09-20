import Vapor

struct TasksIdLogsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "tasks", ":id", "logs", use: TasksIdLogsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
