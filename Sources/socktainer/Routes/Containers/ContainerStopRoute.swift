import Vapor

struct ContainerStopRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/stop", use: ContainerStopRoute.handler(client: client))
    }
}

struct ContainerStopQuery: Content {
    let signal: String?
    let t: Int?/// Number of seconds to wait before stopping the container
}

extension ContainerStopRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerStopQuery.self)
            let signal = query.signal
            let timeout = query.t

            let snapshot = try? await client.getContainer(id: id)

            do {
                try await client.stop(id: id, signal: signal, timeout: timeout)
            } catch ClientContainerError.notFound {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            } catch {
                req.logger.error("Failed to stop container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to stop container: \(error)")
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let event = DockerEvent.simpleEvent(
                id: id,
                type: "container",
                status: "stop",
                image: snapshot?.configuration.image.reference ?? "",
                name: snapshot?.id ?? id,
                labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:])
            )
            await broadcaster.broadcast(event)

            return .noContent
        }
    }
}
