import Vapor

struct ContainerStartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/start", use: ContainerStartRoute.handler(client: client))
    }
}

struct ContainerStartQuery: Content {
    /// Override the key sequence for detaching a container
    let detachKeys: String?
}

extension ContainerStartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in

            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerStartQuery.self)
            let detachKeys = query.detachKeys

            do {
                guard let container = try await client.getContainer(id: id) else {
                    throw Abort(.notFound, reason: "No such container: \(id)")
                }

                // If container is already running, return success (Docker CLI behavior)
                if container.status == .running {
                    req.logger.debug("Container \(id) is already running")
                } else {
                    // Try to start the container
                    try await client.start(id: id, detachKeys: detachKeys)
                    req.logger.debug("Started container \(id)")
                }

            } catch {
                // Check if error indicates container is already running/bootstrapped
                let errorMessage = error.localizedDescription
                let isAlreadyRunning =
                    errorMessage.contains("booted") || errorMessage.contains("expected to be in created state") || errorMessage.contains("invalidState")
                    || errorMessage.contains("already running")

                guard isAlreadyRunning else {
                    req.logger.error("Failed to start container \(id): \(error)")
                    throw Abort(.internalServerError, reason: "Failed to start container: \(error)")
                }
                req.logger.debug("Container \(id) was already running or bootstrapped")
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!

            let event = DockerEvent.simpleEvent(id: id, type: "container", status: "start")

            await broadcaster.broadcast(event)

            // should return 204 HTTP code
            return .noContent
        }
    }
}
