import Foundation
import Vapor

struct RESTBuildPruneQuery: Content {
    let filters: String?
    let all: Bool?
    let keepStorage: Int64?
    let reservedSpace: Int64?
    let maxUsedSpace: Int64?
    let minFreeSpace: Int64?

    enum CodingKeys: String, CodingKey {
        case filters
        case all
        case keepStorage = "keep-storage"
        case reservedSpace = "reserved-space"
        case maxUsedSpace = "max-used-space"
        case minFreeSpace = "min-free-space"
    }
}

struct RESTBuildPruneResponse: Content {
    let CachesDeleted: [String]?
    let SpaceReclaimed: Int64
}

struct BuildPruneRoute: RouteCollection {
    let builderClient: ClientBuilderProtocol

    init(builderClient: ClientBuilderProtocol) {
        self.builderClient = builderClient
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/build/prune", use: handler)
    }

    func handler(_ req: Request) async throws -> RESTBuildPruneResponse {
        let query = try req.query.decode(RESTBuildPruneQuery.self)
        let logger = req.logger
        let parsedFilters = try DockerBuildFilterUtility.parseBuildPruneFilters(filtersParam: query.filters, logger: logger)

        do {
            let result = try await builderClient.prune(
                BuilderPruneRequest(
                    all: query.all ?? false,
                    filters: parsedFilters,
                    keepStorage: query.keepStorage,
                    reservedSpace: query.reservedSpace,
                    maxUsedSpace: query.maxUsedSpace,
                    minFreeSpace: query.minFreeSpace
                ),
                logger: logger
            )

            // moby's BuildPrune emits a single aggregate `builder prune` event (no
            // per-cache-entry events), mirroring the volume/network prune events above.
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "builder", action: "prune", actorID: "",
                        attributes: ["reclaimed": String(result.spaceReclaimed)]))
            }

            return RESTBuildPruneResponse(
                CachesDeleted: result.deletedCaches.isEmpty ? nil : result.deletedCaches,
                SpaceReclaimed: result.spaceReclaimed
            )
        } catch {
            logger.error("Failed to prune build cache via buildctl: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune build cache: \(error.localizedDescription)")
        }
    }
}
