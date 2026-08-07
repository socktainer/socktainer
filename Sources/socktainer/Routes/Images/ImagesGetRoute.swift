import Containerization
import Vapor

struct ImagesGetRoute: RouteCollection {
    let client: ClientImageProtocol

    init(client: ClientImageProtocol) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/get", use: ImagesGetRoute.handlerMultiple(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/get", use: ImagesGetRoute.handlerSingle(client: client))
    }

    static func handlerSingle(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Image name is required")
            }

            return try await saveImages(references: [name], req: req, client: client)
        }
    }

    static func handlerMultiple(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let names = try? req.query.get([String].self, at: "names")

            guard let names = names, !names.isEmpty else {
                throw Abort(.badRequest, reason: "At least one image name is required in 'names' query parameter")
            }

            return try await saveImages(references: names, req: req, client: client)
        }
    }

    private static func saveImages(references: [String], req: Request, client: ClientImageProtocol) async throws -> Response {
        let platformString = try? req.query.get(String.self, at: "platform")
        let platform = try platformString.map(platformOrThrow)

        guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
            throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
        }

        let savedArchive: SavedImageArchive?
        let tarballPath: URL
        do {
            if let identitySavingClient = client as? any ImageSavingWithIdentity {
                let saved = try await identitySavingClient.saveWithIdentities(
                    references: references,
                    platform: platform,
                    appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                    logger: req.logger
                )
                savedArchive = saved
                tarballPath = saved.url
            } else {
                savedArchive = nil
                tarballPath = try await client.save(
                    references: references,
                    platform: platform,
                    appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                    logger: req.logger
                )
            }
        } catch let error as ClientImageError {
            switch error {
            case .notFound(let id):
                throw Abort(.notFound, reason: "No such image: \(id)")
            case .digestReferenceNotAllowed(let repo):
                throw Abort(.badRequest, reason: "cannot reference \(repo) by digest")
            case .conflict(let message):
                throw Abort(.conflict, reason: message)
            }
        }
        let tempDir = tarballPath.deletingLastPathComponent()

        // moby emits one "save" event per exported image with the digest as Actor.ID
        // (daemon/containerd/image_exporter.go). A reference the store cannot resolve
        // to a digest is carried as-is.
        let actorIDs: [String]
        if let savedArchive {
            actorIDs = savedArchive.actorIDs
        } else {
            let identityProvider = client as? any ImageConfigIdentityProviding
            let digestsByReference = await client.digestsByReference()
            var fallbackActorIDs: [String] = []
            for reference in references {
                fallbackActorIDs.append(
                    await identityProvider?.configDigest(for: reference)
                        ?? digestsByReference[reference]
                        ?? reference
                )
            }
            actorIDs = fallbackActorIDs
        }
        let broadcaster = req.application.storage[EventBroadcasterKey.self]

        let response: Response
        do {
            response = try await req.fileio.asyncStreamFile(
                at: tarballPath.path
            ) { result in
                defer { try? FileManager.default.removeItem(at: tempDir) }
                guard case .success = result, let broadcaster else { return }
                for actorId in actorIDs {
                    await broadcaster.broadcast(
                        DockerEvent.make(
                            type: "image", action: "save", actorID: actorId,
                            attributes: ["name": actorId]))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }

        response.headers.contentType = HTTPMediaType(type: "application", subType: "x-tar")

        // Vapor does not invoke `onCompleted` for a conditional 304 response.
        // No body owns the file in that case, so cleanup is immediate.
        if response.status == .notModified {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return response
    }
}
