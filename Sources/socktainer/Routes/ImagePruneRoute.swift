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
        routes.post(":version", "images", "prune", use: handler)
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
