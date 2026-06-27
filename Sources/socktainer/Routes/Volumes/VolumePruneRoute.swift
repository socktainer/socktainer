import Vapor

struct RESTVolumesPruneQuery: Content {
    let filters: String?
}

struct VolumePruneRoute: RouteCollection {
    let client: ClientVolumeService
    init(client: ClientVolumeService) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/volumes/prune", use: self.handler)
    }

    struct PruneResponse: Content {
        let VolumesDeleted: [String]
        let SpaceReclaimed: Int64
    }

    func handler(_ req: Request) async throws -> PruneResponse {
        let logger = req.logger
        let query = try req.query.decode(RESTVolumesPruneQuery.self)
        let filtersParam = query.filters
        let parsedFilters = try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: filtersParam, logger: logger)
        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)
        let filteredVolumes = try await client.list(filters: filtersJSONString, logger: logger)

        var volumesDeleted: [String] = []
        // we do not calculate reclaimed space at the moment
        // limitation with Apple container
        let spaceReclaimed: Int64 = 0
        let broadcaster = req.application.storage[EventBroadcasterKey.self]
        for volume in filteredVolumes {
            do {
                try await client.delete(name: volume.Name)
                volumesDeleted.append(volume.Name)
                // moby fires a `destroy` per removed volume before the aggregate prune.
                if let broadcaster {
                    await broadcaster.broadcast(
                        DockerEvent.make(
                            type: "volume", action: "destroy", actorID: volume.Name,
                            attributes: ["driver": volume.Driver]))
                }
            } catch {
                logger.warning("Failed to delete volume \(volume.Name): \(error)")
            }
        }
        if let broadcaster {
            // The aggregate prune event carries an empty Actor.ID and the bytes reclaimed.
            await broadcaster.broadcast(
                DockerEvent.make(
                    type: "volume", action: "prune", actorID: "",
                    attributes: ["reclaimed": String(spaceReclaimed)]))
        }
        return PruneResponse(VolumesDeleted: volumesDeleted, SpaceReclaimed: spaceReclaimed)
    }
}
