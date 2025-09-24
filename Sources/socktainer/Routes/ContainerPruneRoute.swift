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
        routes.post(":version", "containers", "prune", use: handler)
    }
}

extension ContainerPruneRoute {
    func handler(req: Request) async throws -> RESTContainerPruneResponse {
        let query = try req.query.decode(RESTContainerPruneQuery.self)
        let logger = req.logger

        let parsedFilters = try DockerContainerFilterUtility.parseContainerPruneFilters(filtersParam: query.filters, logger: logger)

        do {
            let result = try await client.prune(filters: parsedFilters)
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
