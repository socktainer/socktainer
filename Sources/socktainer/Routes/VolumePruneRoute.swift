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
        routes.post(":version", "volumes", "prune", use: self.handler)
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
        for volume in filteredVolumes {
            do {
                try await client.delete(name: volume.Name)
                volumesDeleted.append(volume.Name)
            } catch {
                logger.warning("Failed to delete volume \(volume.Name): \(error)")
            }
        }
        return PruneResponse(VolumesDeleted: volumesDeleted, SpaceReclaimed: spaceReclaimed)
    }
}
