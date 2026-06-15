import Vapor

struct ContainerRestartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/restart", use: ContainerRestartRoute.handler(client: client))
    }
}

struct ContainerRestartQuery: Content {
    let signal: String?
    let t: Int?/// Number of seconds to wait before killing the container
}

extension ContainerRestartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerRestartQuery.self)
            let signal = query.signal
            let timeout = query.t

            let snapshot = try? await client.getContainer(id: id)

            do {
                try await client.restart(id: id, signal: signal, timeout: timeout)
            } catch ClientContainerError.notFound {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            } catch {
                req.logger.error("Failed to restart container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to restart container: \(error)")
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let event = DockerEvent.simpleEvent(
                id: id,
                type: "container",
                status: "restart",
                image: snapshot?.configuration.image.reference ?? "",
                name: snapshot?.id ?? id,
                labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:])
            )
            await broadcaster.broadcast(event)

            return .noContent
        }
    }
}
