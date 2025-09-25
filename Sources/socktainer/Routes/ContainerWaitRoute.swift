import Vapor

public enum ContainerWaitCondition: String, CaseIterable, Codable, Sendable {
    case notRunning = "not-running"
    case nextExit = "next-exit"
    case removed = "removed"

    public static let `default`: ContainerWaitCondition = .notRunning
}

struct ContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "wait", use: ContainerWaitRoute.handler(client: client))
        routes.post("containers", ":id", "wait", use: ContainerWaitRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> RESTContainerWait {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let conditionString = req.query["condition"] as String?
            let condition: ContainerWaitCondition

            if let conditionString = conditionString {
                condition = ContainerWaitCondition(rawValue: conditionString) ?? ContainerWaitCondition.default
            } else {
                condition = ContainerWaitCondition.default
            }

            do {
                let waitResponse = try await client.wait(id: containerId, condition: condition)
                return waitResponse
            } catch ClientContainerError.notFound(let id) {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch {
                throw Abort(.internalServerError, reason: "Failed to wait for container: \(error)")
            }
        }
    }
}
