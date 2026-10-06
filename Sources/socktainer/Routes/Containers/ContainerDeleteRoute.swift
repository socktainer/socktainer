import ContainerAPIClient
import Vapor

struct ContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .DELETE, pattern: "/containers/{id}", use: ContainerDeleteRoute.handler(client: client))
    }

}

struct ContainerDeleteQuery: Content {
    var force: Bool?
    var v: Bool?
}

extension ContainerDeleteRoute {
    static func handler(
        client: ClientContainerProtocol,
        removeVolumes: @escaping @Sendable ([String], Logger) async -> Void = { names, logger in
            await ContainerAnonymousVolumes.remove(names: names, logger: logger)
        }
    ) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerDeleteQuery.self)
            let force = query.force ?? false

            let snapshot = try? await client.getContainer(id: id)
            let cached = await ContainerInfoCache.shared.get(id: snapshot?.id ?? id)

            let eventImage = snapshot?.configuration.image.reference ?? cached?.image ?? ""
            let eventName = snapshot?.id ?? cached?.nativeId ?? id
            let displayName = await ContainerNameOverrideStore.shared.name(forNativeID: eventName)
            let eventLabels =
                snapshot.map { LabelNormalization.restore($0.configuration.labels) }
                ?? cached?.labels ?? [:]
            // Use the canonical 64-char Docker ID so the destroy event matches the id
            // carried by create/start/die — derived from the snapshot, then the cache,
            // falling back to the request reference only when neither is available.
            let eventId = snapshot.map { DockerContainerID.hexId(for: $0) } ?? cached?.hexId ?? id

            func broadcastRemove() async {
                await ContainerInfoCache.shared.remove(id: eventName)
                // Prevents a container recreated under the same name from inheriting this one's restart-attempt count.
                await ContainerRestartState.shared.reset(id: eventName)
                await RestartPolicyOverrideStore.shared.remove(id: eventId)
                // Releases this container's die-event bookkeeping and refuses later claims: an
                // exit monitor still resolving the exit of a container that is now gone would
                // otherwise find no record of the run and emit a `die` for it a second time.
                await DieEventOwnership.shared.forget(id: eventName)
                guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
                await broadcaster.broadcast(
                    DockerEvent.simpleEvent(
                        id: eventId, type: "container", status: "destroy",
                        image: eventImage, name: displayName, labels: eventLabels
                    ))
            }

            do {
                let container = try await client.getContainer(id: id)

                // Docker Engine API: removing a running container requires force=true.
                // Checked before any side effect (healthcheck stop, DNS cleanup) so a
                // rejected delete leaves the container fully intact. A container still
                // shutting down (.stopping) counts as running, as it does in moby.
                if let container, container.status == .running || container.status == .stopping, !force {
                    throw Abort(
                        .conflict,
                        reason: "cannot remove container \"\(id)\": container is running: stop the container before removing or force remove")
                }

                if let healthManager = req.application.storage[HealthCheckManagerKey.self] {
                    if container == nil {
                        req.logger.warning("healthcheck stop: container not found for id \(id), falling back — loop may be orphaned")
                    }
                    await healthManager.stop(containerId: container?.id ?? id)
                }

                if let container,
                    let dnsServer = req.application.storage[SocktainerDNSServerKey.self]
                {
                    // Prefer the cached IP — reliable even once the container has genuinely
                    // stopped and Apple Container reports an empty live network list — falling
                    // back to the live snapshot for a container never observed via /start.
                    let containerIP = ContainerStartRoute.dnsAttachmentIP(in: container)
                    let displayName = await ContainerNameOverrideStore.shared.name(forNativeID: container.id)
                    ContainerAliasCleanup.unregisterAllAliases(
                        nativeId: container.id,
                        displayName: displayName,
                        labels: cached?.labels ?? LabelNormalization.restore(container.configuration.labels),
                        cachedIP: cached?.ip ?? containerIP,
                        dnsServer: dnsServer
                    )
                }

                if let container, container.status == .running {
                    try await client.stop(id: id, signal: nil, timeout: nil)
                }
                try await client.delete(id: id)
                if query.v == true {
                    await removeVolumes(
                        ContainerAnonymousVolumes.names(labels: container?.configuration.labels ?? eventLabels), req.logger)
                }
                if let nativeID = container?.id { try await ContainerNameOverrideStore.shared.remove(nativeID: nativeID) }
            } catch ClientContainerError.notFound {
                if let nativeID = snapshot?.id ?? cached?.nativeId {
                    try await ContainerNameOverrideStore.shared.remove(nativeID: nativeID)
                }
                if snapshot != nil || cached != nil {
                    await broadcastRemove()
                }
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            } catch let abort as Abort {
                // A deliberately-thrown Abort (e.g. the running-container-without-force 409)
                // must propagate as-is, not get rewrapped into a 500 by the catch-all below.
                throw abort
            } catch {
                req.logger.error("Failed to delete container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to delete container: \(error)")
            }

            await broadcastRemove()
            // Docker Engine API: DELETE /containers/{id} returns 204 No Content.
            return .noContent
        }
    }
}
