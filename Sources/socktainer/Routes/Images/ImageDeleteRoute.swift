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

            do {
                try await client.delete(id: imageRef)
            } catch let error as ClientImageError {
                switch error {
                case .notFound(let id):
                    throw Abort(.notFound, reason: "No such image: \(id)")
                }
            }

            // Optional: broadcast event
            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let event = DockerEvent.simpleEvent(id: imageRef, type: "image", status: "remove")
            await broadcaster.broadcast(event)

            let deleteResponse = [
                ImageDeleteResponseItem(Deleted: imageRef, Untagged: nil)
            ]

            return try await deleteResponse.encodeResponse(status: .ok, for: req)

        }
    }
}
