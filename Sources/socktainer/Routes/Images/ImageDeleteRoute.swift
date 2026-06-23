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

            // Broadcast using the normalized reference so event consumers see the
            // canonical form (matches Docker's own event emission).
            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let event = DockerEvent.simpleEvent(
                id: result.untagged, type: "image", status: "remove", image: result.untagged)
            await broadcaster.broadcast(event)

            // Build response matching Docker Engine API:
            //   {Untagged} for the tag that was removed
            //   {Deleted}  for the image layers freed (only when the last reference was removed)
            var deleteResponse = [ImageDeleteResponseItem(Deleted: nil, Untagged: result.untagged)]
            if let digest = result.deletedDigest {
                deleteResponse.append(ImageDeleteResponseItem(Deleted: digest, Untagged: nil))
            }

            return try await deleteResponse.encodeResponse(status: .ok, for: req)

        }
    }
}
