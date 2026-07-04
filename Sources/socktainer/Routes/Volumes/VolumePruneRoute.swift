import ContainerResource
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
        var parsedFilters = try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: filtersParam, logger: logger)
        // Docker Engine API v1.42+: prune removes only anonymous volumes unless
        // the all=true filter is set ('docker volume prune -a'). "all" is a
        // prune directive, not a volume-matching filter, so strip it before list.
        let pruneAll = try Self.parsePruneAll(parsedFilters.removeValue(forKey: "all"))
        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)
        let filteredVolumes = Self.volumesToPrune(
            try await client.list(filters: filtersJSONString, logger: logger),
            pruneAll: pruneAll
        )

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

    /// Parses the "all" prune filter like moby's strconv.ParseBool: at most one
    /// value, and an unrecognized value is a 400 rather than silently false.
    static func parsePruneAll(_ values: [String]?) throws -> Bool {
        guard let values, !values.isEmpty else { return false }
        guard values.count == 1 else {
            throw Abort(.badRequest, reason: "invalid filter 'all': got more than one value")
        }
        switch values[0].lowercased() {
        case "1", "t", "true": return true
        case "0", "f", "false": return false
        default: throw Abort(.badRequest, reason: "invalid filter 'all=\(values[0])'")
        }
    }

    /// Narrows the prune set to anonymous volumes unless all=true was given.
    /// Anonymous volumes carry moby's com.docker.volume.anonymous label
    /// (stamped at auto-creation) or Apple's equivalent for volumes created by
    /// the container CLI itself. Named volumes are never pruned by default,
    /// as in Docker.
    static func volumesToPrune(_ volumes: [Volume], pruneAll: Bool) -> [Volume] {
        guard !pruneAll else { return volumes }
        return volumes.filter {
            $0.Labels?[ClientVolumeService.anonymousVolumeLabel] != nil
                || $0.Labels?[VolumeConfiguration.anonymousLabel] != nil
        }
    }
}
