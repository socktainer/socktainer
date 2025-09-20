import Vapor

struct TasksIdRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "tasks", ":id", use: TasksIdRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        AppleContainerNotSupported.respond("Swarm")
    }
}
