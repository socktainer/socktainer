import Vapor

struct ImageDeleteResponseItem: Content {
    let Deleted: String?
    let Untagged: String?
}

struct ImageDeleteRoute: RouteCollection {
    let client: ClientImageProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/images/{name:.*}", use: ImageDeleteRoute.handler(client: client))
    }

}

extension ImageDeleteRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            // Get image name from regex pattern parameter
            guard let imageRef = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            let result: ImageDeletionResult
            do {
                result = try await client.delete(id: imageRef)
            } catch let error as ClientImageError {
                switch error {
                case .notFound(let id):
                    throw Abort(.notFound, reason: "No such image: \(id)")
                }
            }

            // Docker fires "untag" when a tag is removed, "delete" when the last
            // reference to a digest is removed and the image layers are freed.
            // Both carry the image digest as Actor.ID with the reference in `name`
            // (matches moby's logImageEvent / LogImageEvent shape).
            //
            // moby's imageDeleteHelper (daemon/containerd/image_delete.go) gates both
            // the "untag" event and the response's {Untagged} record on
            // `!isDanglingImage(img)` — dangling images have no real tag to untag, so
            // only "delete" is emitted and returned for them. Verified against
            // moby v28.5.2 source.
            //
            // In this stack a dangling image is stored as "untagged@<digest>" (the
            // sentinel LocalOCILayoutClient assigns when a loaded tarball has no
            // RepoTags — the analogue of moby's "moby-dangling@" name). "<none>" is
            // kept for refs imported verbatim from foreign tarball annotations.
            // A pull-by-digest ref (repo@sha256:…) is NOT dangling and keeps its
            // Untagged record, as in moby.
            let isDangling = result.untagged.hasPrefix("untagged@") || result.untagged.contains("<none>")

            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                if !isDangling {
                    await broadcaster.broadcast(
                        DockerEvent.make(
                            type: "image", action: "untag", actorID: result.digest,
                            attributes: ["name": result.untagged]))
                }
                if let digest = result.deletedDigest {
                    await broadcaster.broadcast(
                        DockerEvent.make(
                            type: "image", action: "delete", actorID: digest,
                            attributes: ["name": digest]))
                }
            }

            // Build response matching Docker Engine API:
            //   {Untagged} for the tag that was removed (omitted for dangling images)
            //   {Deleted}  for the image layers freed (only when the last reference was removed)
            var deleteResponse: [ImageDeleteResponseItem] = []
            if !isDangling {
                deleteResponse.append(ImageDeleteResponseItem(Deleted: nil, Untagged: result.untagged))
            }
            if let digest = result.deletedDigest {
                deleteResponse.append(ImageDeleteResponseItem(Deleted: digest, Untagged: nil))
            }

            return try await deleteResponse.encodeResponse(status: .ok, for: req)

        }
    }
}
