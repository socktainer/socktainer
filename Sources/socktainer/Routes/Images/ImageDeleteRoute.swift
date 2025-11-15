import Vapor

struct ImageDeleteRoute: RouteCollection {
    let client: ClientImageProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/images/{name:.*}", use: ImageDeleteRoute.handler(client: client))
    }

}

extension ImageDeleteRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            // Get image name from regex pattern parameter
            guard let imageRef = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            try await client.delete(id: imageRef)

            // Optional: broadcast event
            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let event = DockerEvent.simpleEvent(id: imageRef, type: "image", status: "remove")
            await broadcaster.broadcast(event)

            return .ok

        }
    }
}
