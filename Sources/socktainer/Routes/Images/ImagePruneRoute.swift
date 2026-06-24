import Vapor

struct RESTImagePruneQuery: Content {
    let filters: String?
}

struct RESTImageDeletedItem: Content {
    let Deleted: String?
    let Untagged: String?
}

struct RESTImagePruneResponse: Content {
    let ImagesDeleted: [RESTImageDeletedItem]?
    let SpaceReclaimed: Int64
}

struct ImagePruneRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/prune", use: handler)
    }
}

extension ImagePruneRoute {
    func handler(req: Request) async throws -> RESTImagePruneResponse {
        let query = try req.query.decode(RESTImagePruneQuery.self)
        let logger = req.logger

        let parsedFilters = DockerImageFilterUtility.parseImagePruneFilters(filterParam: query.filters, logger: logger)

        do {
            let result = try await client.prune(filters: parsedFilters, logger: logger)

            let imagesDeleted = result.deletedImages.map { imageRef in
                RESTImageDeletedItem(Deleted: imageRef, Untagged: nil)
            }

            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // Docker prune events carry an empty Actor.ID and only the bytes reclaimed.
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "image", action: "prune", actorID: "",
                        attributes: ["reclaimed": String(result.spaceReclaimed)]))
            }
            return RESTImagePruneResponse(
                ImagesDeleted: imagesDeleted.isEmpty ? nil : imagesDeleted,
                SpaceReclaimed: result.spaceReclaimed
            )
        } catch {
            req.logger.error("Failed to prune images: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune images: \(error.localizedDescription)")
        }
    }
}
