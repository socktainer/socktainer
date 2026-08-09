import ContainerAPIClient
import ContainerResource
import Vapor

struct RESTContainerPruneQuery: Content {
    let filters: String?
}

struct RESTContainerPruneResponse: Content {
    let ContainersDeleted: [String]
    let SpaceReclaimed: Int64
}

struct ContainerPruneRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/prune", use: handler)
    }
}

extension ContainerPruneRoute {
    func handler(req: Request) async throws -> RESTContainerPruneResponse {
        let query = try req.query.decode(RESTContainerPruneQuery.self)
        let logger = req.logger

        let parsedFilters = try DockerContainerFilterUtility.parseContainerPruneFilters(filtersParam: query.filters, logger: logger)

        do {
            // Capture snapshots before pruning so the per-container `destroy` events can
            // carry image/name/labels (moby emits a `destroy` per removed container, then
            // the aggregate `prune`). The container is gone by the time prune() returns.
            // Never prune without the identity snapshot needed to clean durable
            // aliases, listeners and caches. A transient list failure must fail
            // closed before the destructive backend call.
            let preSnapshots = try await client.list(showAll: true, filters: [:])
            var snapshotByID: [String: ContainerSnapshot] = [:]
            var logicalNameByNativeID: [String: String] = [:]
            for snapshot in preSnapshots {
                snapshotByID[DockerContainerID.hexId(for: snapshot)] = snapshot
                snapshotByID[snapshot.id] = snapshot
                logicalNameByNativeID[snapshot.id] = await DockerContainerMetadataStore.shared.name(
                    nativeID: snapshot.id
                )
            }

            let result = try await client.prune(filters: parsedFilters)
            var dockerDeletedIDs: [String] = []
            for deletedID in result.deletedContainers {
                guard let snapshot = snapshotByID[deletedID] else {
                    dockerDeletedIDs.append(deletedID)
                    continue
                }
                let nativeID = snapshot.id
                let hexID = DockerContainerID.hexId(for: snapshot)
                let logicalName = logicalNameByNativeID[nativeID] ?? nativeID
                dockerDeletedIDs.append(hexID)
                await req.application.storage[DynamicPortAllocatorKey.self]?.release(
                    nativeID: nativeID
                )
                await req.application.storage[HealthCheckManagerKey.self]?.stop(containerId: nativeID)
                if let dnsServer = req.application.storage[SocktainerDNSServerKey.self] {
                    ContainerAliasCleanup.unregisterAllAliases(
                        nativeId: nativeID,
                        logicalName: logicalName,
                        labels: ContainerImageIdentity.dockerLabels(for: snapshot),
                        cachedIP: ContainerStartRoute.dnsAttachmentIP(in: snapshot),
                        dnsServer: dnsServer
                    )
                }
                await ContainerInfoCache.shared.remove(id: hexID)
                await ContainerRestartState.shared.reset(id: nativeID)
                await RestartPolicyOverrideStore.shared.remove(id: hexID)
                try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            }
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // moby fires a `destroy` per removed container before the aggregate prune.
                for (index, containerID) in result.deletedContainers.enumerated() {
                    let snapshot = snapshotByID[containerID]
                    let dockerID = dockerDeletedIDs[index]
                    await broadcaster.broadcast(
                        DockerEvent.simpleEvent(
                            id: dockerID,
                            type: "container",
                            status: "destroy",
                            image: snapshot.map {
                                ContainerImageIdentity.requestedReference(
                                    for: $0
                                )
                            } ?? "",
                            name: snapshot.flatMap { logicalNameByNativeID[$0.id] }
                                ?? containerID,
                            labels: snapshot.map {
                                ContainerImageIdentity.dockerLabels(for: $0)
                            } ?? [:]))
                }
                // The aggregate prune event carries an empty Actor.ID and the bytes reclaimed.
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "container", action: "prune", actorID: "",
                        attributes: ["reclaimed": String(result.spaceReclaimed)]))
            }
            return RESTContainerPruneResponse(
                ContainersDeleted: dockerDeletedIDs,
                SpaceReclaimed: result.spaceReclaimed
            )
        } catch {
            req.logger.error("Failed to prune containers: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune containers: \(error.localizedDescription)")
        }
    }
}
