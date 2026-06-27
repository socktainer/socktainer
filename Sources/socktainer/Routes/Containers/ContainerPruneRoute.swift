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
            let preSnapshots = (try? await client.list(showAll: true, filters: [:])) ?? []
            var snapshotByID: [String: ContainerSnapshot] = [:]
            for snapshot in preSnapshots {
                snapshotByID[DockerContainerID.hexId(for: snapshot)] = snapshot
                snapshotByID[snapshot.id] = snapshot
            }

            let result = try await client.prune(filters: parsedFilters)
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // moby fires a `destroy` per removed container before the aggregate prune.
                for containerID in result.deletedContainers {
                    let snapshot = snapshotByID[containerID]
                    await broadcaster.broadcast(
                        DockerEvent.simpleEvent(
                            id: containerID,
                            type: "container",
                            status: "destroy",
                            image: snapshot?.configuration.image.reference ?? "",
                            name: snapshot?.id ?? containerID,
                            labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:])))
                }
                // The aggregate prune event carries an empty Actor.ID and the bytes reclaimed.
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "container", action: "prune", actorID: "",
                        attributes: ["reclaimed": String(result.spaceReclaimed)]))
            }
            return RESTContainerPruneResponse(
                ContainersDeleted: result.deletedContainers,
                SpaceReclaimed: result.spaceReclaimed
            )
        } catch {
            req.logger.error("Failed to prune containers: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune containers: \(error.localizedDescription)")
        }
    }
}
