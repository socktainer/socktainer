import Vapor

struct ContainerRenameRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/rename", use: ContainerRenameRoute.handler(client: client))
    }
}

struct ContainerRenameQuery: Content {
    let name: String?
}

extension ContainerRenameRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            // Docker accepts the new name with or without its leading slash.
            let name = (try req.query.decode(ContainerRenameQuery.self).name ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty else {
                throw Abort(.badRequest, reason: "Neither old nor new names may be empty")
            }

            do {
                try await client.rename(id: id, newName: name)
            } catch ClientContainerError.notFound {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            } catch ClientContainerError.invalidName(let name) {
                throw Abort(.badRequest, reason: "Invalid container name (\(name))")
            } catch ClientContainerError.nameConflict(let name) {
                throw Abort(.conflict, reason: "Conflict. The container name \"/\(name)\" is already in use.")
            } catch ClientContainerError.renameRequiresUnstarted(let containerId) {
                throw Abort(
                    .conflict,
                    reason:
                        "Cannot rename container \(containerId): socktainer can only rename containers that have never been started"
                )
            } catch {
                req.logger.error("Failed to rename container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to rename container: \(error)")
            }
            return .noContent
        }
    }
}
