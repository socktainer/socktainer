import ContainerAPIClient
import ContainerPersistence
import Vapor

struct ImageTagRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/tag") { [systemConfig] req in
            try await ImageTagRoute.handler(req, systemConfig: systemConfig)
        }
    }
}

struct RESTImageTagQuery: Vapor.Content {
    let repo: String?
    let tag: String?
}

extension ImageTagRoute {
    static func handler(_ req: Request, systemConfig: ContainerSystemConfig) async throws -> Response {
        guard let sourceImageName = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing image name parameter")
        }

        let query = try req.query.decode(RESTImageTagQuery.self)

        guard let repo = query.repo, !repo.isEmpty else {
            throw Abort(.badRequest, reason: "repo parameter is required")
        }

        let targetReference = try {
            if let tag = query.tag, !tag.isEmpty {
                return try ClientImage.normalizeReference("\(repo):\(tag)", containerSystemConfig: systemConfig)
            }
            return try ClientImage.normalizeReference(repo, containerSystemConfig: systemConfig)
        }()

        let sourceImage: ClientImage
        do {
            sourceImage = try await ClientImage.get(reference: sourceImageName, containerSystemConfig: systemConfig)
        } catch {
            throw Abort(.notFound, reason: "No such image: \(sourceImageName)")
        }

        do {
            _ = try await sourceImage.tag(new: targetReference)
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // moby's tag event uses the image digest as Actor.ID and the new
                // reference as the `name` attribute.
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "image", action: "tag", actorID: sourceImage.digest,
                        attributes: ["name": targetReference]))
            }
            return Response(status: .created)
        } catch {
            req.logger.error("Failed to tag image: \(error)")
            throw Abort(.internalServerError, reason: "Failed to tag image: \(error.localizedDescription)")
        }
    }
}
