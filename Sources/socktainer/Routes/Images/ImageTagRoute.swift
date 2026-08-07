import ContainerAPIClient
import ContainerPersistence
import Vapor

struct ImageTagRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig
    let identityResolver: ImageIdentityResolver
    let tagger: any ImageTaggingProtocol

    init(
        systemConfig: ContainerSystemConfig,
        identityResolver: ImageIdentityResolver? = nil,
        tagger: (any ImageTaggingProtocol)? = nil
    ) {
        let resolver = identityResolver ?? ImageIdentityResolver(systemConfig: systemConfig)
        self.systemConfig = systemConfig
        self.identityResolver = resolver
        self.tagger =
            tagger
            ?? ClientImageService(
                containerSystemConfig: systemConfig,
                identityResolver: resolver
            )
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/tag") { [systemConfig, identityResolver, tagger] req in
            try await ImageTagRoute.handler(
                req,
                systemConfig: systemConfig,
                identityResolver: identityResolver,
                tagger: tagger
            )
        }
    }
}

struct RESTImageTagQuery: Vapor.Content {
    let repo: String?
    let tag: String?
}

extension ImageTagRoute {
    static func handler(
        _ req: Request,
        systemConfig: ContainerSystemConfig,
        identityResolver: ImageIdentityResolver? = nil,
        tagger: (any ImageTaggingProtocol)? = nil
    ) async throws -> Response {
        let resolver = identityResolver ?? ImageIdentityResolver(systemConfig: systemConfig)
        let imageTagger =
            tagger
            ?? ClientImageService(
                containerSystemConfig: systemConfig,
                identityResolver: resolver
            )
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

        do {
            let tagged = try await imageTagger.tag(
                source: sourceImageName,
                target: targetReference
            )
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // moby's tag event uses the image digest as Actor.ID and the new
                // reference as the `name` attribute (no `image`/`from` for image events).
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "image", action: "tag",
                        actorID: tagged.dockerConfigDigest,
                        attributes: ["name": targetReference]))
            }
            return Response(status: .created)
        } catch ClientImageError.notFound {
            throw Abort(.notFound, reason: "No such image: \(sourceImageName)")
        } catch ClientImageError.conflict(let message) {
            throw Abort(.conflict, reason: message)
        } catch {
            req.logger.error("Failed to tag image: \(error)")
            throw Abort(.internalServerError, reason: "Failed to tag image: \(error.localizedDescription)")
        }
    }
}
