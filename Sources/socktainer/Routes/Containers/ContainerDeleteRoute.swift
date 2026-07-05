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
}

extension ContainerDeleteRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let force = try req.query.decode(ContainerDeleteQuery.self).force ?? false

            let snapshot = try? await client.getContainer(id: id)
            let cached = await ContainerInfoCache.shared.get(id: id)

            let eventImage = snapshot?.configuration.image.reference ?? cached?.image ?? ""
            let eventName = snapshot?.id ?? cached?.nativeId ?? id
            let eventLabels =
                snapshot.map { LabelNormalization.restore($0.configuration.labels) }
                ?? cached?.labels ?? [:]
            // Use the canonical 64-char Docker ID so the destroy event matches the id
            // carried by create/start/die — derived from the snapshot, then the cache,
            // falling back to the request reference only when neither is available.
            let eventId = snapshot.map { DockerContainerID.hexId(for: $0) } ?? cached?.hexId ?? id

            func broadcastRemove() async {
                await ContainerInfoCache.shared.remove(id: id)
                guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
                await broadcaster.broadcast(
                    DockerEvent.simpleEvent(
                        id: eventId, type: "container", status: "destroy",
                        image: eventImage, name: eventName, labels: eventLabels
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
                    let containerIP = container.networks.first?.ipv4Address.address.description

                    // Only unregister an alias when this container still owns it — i.e. the
                    // registered IP matches ours. If another container has since claimed the
                    // same hostname (e.g. a second project with an identically-named service),
                    // leave the entry intact so that surviving container keeps resolving.
                    func unregisterIfOwned(_ hostname: String) {
                        let registered = dnsServer.listEntries()[SocktainerDNSServer.normalize(hostname)]
                        if let containerIP, registered != nil, registered != containerIP { return }
                        dnsServer.unregister(hostname: hostname)
                    }

                    // Mirror of the container-name registration in the start route.
                    if !container.id.isEmpty {
                        unregisterIfOwned(container.id)
                    }
                    if let namesLabel = container.configuration.labels["socktainer.dns.names"] {
                        for name in namesLabel.split(separator: ",").map(String.init) where !name.isEmpty {
                            unregisterIfOwned(name)
                        }
                    }
                    if let serviceName = container.configuration.labels["com.docker.compose.service"],
                        !serviceName.isEmpty
                    {
                        unregisterIfOwned(serviceName)
                        if let projectName = container.configuration.labels["com.docker.compose.project"],
                            !projectName.isEmpty
                        {
                            unregisterIfOwned("\(serviceName).\(projectName)")
                        }
                    }
                }

                if let container, container.status == .running {
                    try await client.stop(id: id, signal: nil, timeout: nil)
                }
                try await client.delete(id: id)
            } catch ClientContainerError.notFound {
                if snapshot != nil || cached != nil {
                    await broadcastRemove()
                }
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
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
