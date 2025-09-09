import Vapor

struct ContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "json", use: ContainerInspectRoute.handler(client: client))
        // also handle without version prefix
        routes.get("containers", ":id", "json", use: ContainerInspectRoute.handler(client: client))

    }
}

extension ContainerInspectRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> RESTContainerSummary {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            return RESTContainerSummary(
                Id: container.id,
                Names: ["/" + container.id],
                Image: container.configuration.image.reference,
                ImageID: container.configuration.image.digest,
                State: container.status.rawValue
            )
        }
    }
}
