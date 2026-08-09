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
                await req.application.storage[PublishedPortManagerKey.self]?.close(nativeID: nativeId)
            }

            do {
                if let snapshot, !snapshot.configuration.publishedPorts.isEmpty,
                    let appSupportURL = req.application.storage[AppleContainerAppSupportUrlKey.self]
                {
                    try await DockerContainerMetadataStore.shared.adopt(
                        nativeID: snapshot.id,
                        name: snapshot.id,
                        publishedPorts: snapshot.configuration.publishedPorts
                    )
                    try await client.stop(id: id, signal: signal, timeout: timeout)
                    var stopped = snapshot
                    if let refreshed = try await client.getContainer(nativeID: snapshot.id) { stopped = refreshed }
                    try ApplePublishedPortCompatibility.suppressNativeForwarder(
                        container: stopped,
                        appSupportURL: appSupportURL
                    )
                    try await client.start(id: id, detachKeys: nil)
                } else {
                    try await client.restart(id: id, signal: signal, timeout: timeout)
                }
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
            let dockerName: String
            if let snapshot {
                dockerName = await DockerContainerMetadataStore.shared.name(nativeID: snapshot.id)
            } else {
                dockerName = id
            }
            // Carry the canonical 64-char Docker id, not the raw request
            // reference (name or short id), so clients can correlate this
            // event with start/kill/die (same pattern as those routes).
            let event = DockerEvent.simpleEvent(
                id: snapshot.map { DockerContainerID.hexId(for: $0) } ?? id,
                type: "container",
                status: "restart",
                image: snapshot.map {
                    ContainerImageIdentity.requestedReference(for: $0)
                } ?? "",
                name: dockerName,
                labels: snapshot.map {
                    ContainerImageIdentity.dockerLabels(for: $0)
                } ?? [:]
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
                try await req.application.storage[PublishedPortManagerKey.self]?.reconcile(container: snap)
                let restartedName = await DockerContainerMetadataStore.shared.name(nativeID: snap.id)
                let eventId = DockerContainerID.hexId(for: snap)
                let restartPolicy = RestartPolicyManager.decode(from: snap.configuration.labels)
                let generation = await ContainerRestartState.shared.currentGeneration(id: snap.id)
                await ContainerStartRoute.armRestartObserver(
                    nativeId: snap.id,
                    eventId: eventId,
                    image: ContainerImageIdentity.requestedReference(
                        for: snap
                    ),
                    name: restartedName,
                    labels: ContainerImageIdentity.dockerLabels(for: snap),
                    rootDescriptor: snap.configuration.image.descriptor,
                    ip: ContainerStartRoute.dnsAttachmentIP(in: snap),
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
