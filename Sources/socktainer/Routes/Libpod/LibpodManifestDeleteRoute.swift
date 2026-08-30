import Vapor

struct RESTManifestDeleteQuery: Content {
    let ignore: Bool?
}

/// Real podman's `ManifestDelete` handler (`pkg/api/handlers/libpod/manifests.go`) returns
/// `LibpodImagesRemoveReport` (`entities.ImageRemoveReport` embedded, plus `Errors`) — not a
/// bare `IDResponse{Id}`. JSON keys match the embedded Go struct's field names verbatim
/// (`Deleted`/`Untagged`/`ExitCode`/`Errors`), matching what a real podman CLI decodes.
struct RESTManifestRemoveReport: Content {
    let Deleted: [String]
    let Untagged: [String]
    let ExitCode: Int
    let Errors: [String]
}

struct LibpodManifestDeleteRoute: RouteCollection {
    let client: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/manifests/{name:.*}", use: LibpodManifestDeleteRoute.handler(client: client))
    }

    static func handler(client: ClientManifestServiceProtocol) -> @Sendable (Request) async throws -> RESTManifestRemoveReport {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing manifest list name")
            }
            let query: RESTManifestDeleteQuery
            do {
                query = try req.query.decode(RESTManifestDeleteQuery.self)
            } catch {
                throw Abort(.badRequest, reason: "Invalid query parameters: \(error)")
            }
            let ignore = query.ignore ?? false

            guard try await client.exists(name: name) else {
                if ignore {
                    return RESTManifestRemoveReport(Deleted: [], Untagged: [], ExitCode: 0, Errors: [])
                }
                throw Abort(.notFound, reason: "No such manifest list: \(name)")
            }
            do {
                try await client.delete(name: name)
            } catch is ClientManifestError {
                if ignore {
                    return RESTManifestRemoveReport(Deleted: [], Untagged: [], ExitCode: 0, Errors: [])
                }
                throw Abort(.notFound, reason: "No such manifest list: \(name)")
            }
            return RESTManifestRemoveReport(Deleted: [name], Untagged: [], ExitCode: 0, Errors: [])
        }
    }
}
