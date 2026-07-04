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

            if let nativeId = snapshot?.id {
                await ContainerRestartState.shared.reset(id: nativeId)
            }

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
            // Carry the canonical 64-char Docker id, not the raw request
            // reference (name or short id), so clients can correlate this
            // event with start/kill/die (same pattern as those routes).
            let event = DockerEvent.simpleEvent(
                id: snapshot.map { DockerContainerID.hexId(for: $0) } ?? id,
                type: "container",
                status: "restart",
                image: snapshot?.configuration.image.reference ?? "",
                name: snapshot?.id ?? id,
                labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:])
            )
            await broadcaster.broadcast(event)

            // Re-arm restart-policy enforcement the same way /start does — otherwise a
            // manually-restarted container has no observer watching its next exit.
            let dnsServer = req.application.storage[SocktainerDNSServerKey.self]
            let healthManager = req.application.storage[HealthCheckManagerKey.self]
            let restartedSnapshot = await ContainerStartRoute.performPostStartSetup(
                id: id, client: client, dnsServer: dnsServer, healthManager: healthManager, logger: req.logger
            )
            if let snap = restartedSnapshot {
                let eventId = DockerContainerID.hexId(for: snap)
                let restartPolicy = RestartPolicyManager.decode(from: snap.configuration.labels)
                let generation = await ContainerRestartState.shared.currentGeneration(id: snap.id)
                await ContainerStartRoute.armRestartObserver(
                    nativeId: snap.id,
                    eventId: eventId,
                    image: snap.configuration.image.reference,
                    name: snap.id,
                    labels: LabelNormalization.restore(snap.configuration.labels),
                    ip: snap.networks.first?.ipv4Address.address.description,
                    refreshCache: true,
                    restartPolicy: restartPolicy,
                    generation: generation,
                    broadcaster: broadcaster,
                    dnsServer: dnsServer,
                    healthManager: healthManager,
                    client: client,
                    logger: req.logger
                )
            }

            return .noContent
        }
    }
}
