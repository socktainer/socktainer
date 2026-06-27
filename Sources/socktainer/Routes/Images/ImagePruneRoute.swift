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

            // moby emits per-image `untag`/`delete` events for prune (NOT an aggregate "prune"
            // event — that exists for containers/networks/volumes but not images). Mirror the
            // exact emission of ImageDeleteRoute: untag per removed reference (Actor.ID = digest),
            // delete per freed digest.
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                for item in result.results {
                    await broadcaster.broadcast(
                        DockerEvent.make(
                            type: "image", action: "untag", actorID: item.digest,
                            attributes: ["name": item.untagged]))
                    if let digest = item.deletedDigest {
                        await broadcaster.broadcast(
                            DockerEvent.make(
                                type: "image", action: "delete", actorID: digest,
                                attributes: ["name": digest]))
                    }
                }
            }

            // Response mirrors moby: an Untagged entry per removed reference and a Deleted entry
            // per freed digest.
            var imagesDeleted: [RESTImageDeletedItem] = []
            for item in result.results {
                imagesDeleted.append(RESTImageDeletedItem(Deleted: nil, Untagged: item.untagged))
                if let digest = item.deletedDigest {
                    imagesDeleted.append(RESTImageDeletedItem(Deleted: digest, Untagged: nil))
                }
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
