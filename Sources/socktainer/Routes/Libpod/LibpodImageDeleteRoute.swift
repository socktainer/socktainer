import Vapor

/// Podman removes images through `DELETE /libpod/images/remove?images=a&images=b` (batch) and
/// `DELETE /libpod/images/{name}` (one); both answer a `LibpodImagesRemoveReport`, not Docker's
/// array of `{Untagged}`/`{Deleted}` items. Each image goes through the Docker-compat handler.
struct LibpodImageDeleteRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/images/remove", use: LibpodImageDeleteRoute.batchHandler(client: client))
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/images/{name:.*}", use: LibpodImageDeleteRoute.singleHandler(client: client))
    }

    static func batchHandler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        let docker = ImageDeleteRoute.handler(client: client)
        return { req in
            let images =
                req.url.query.map { query in
                    URLComponents(string: "?" + query)?.queryItems?.filter { $0.name == "images" }.compactMap(\.value) ?? []
                } ?? []
            guard !images.isEmpty else {
                throw Abort(.badRequest, reason: "no images specified")
            }
            let ignoreMissing = (req.query["ignore"] as Bool?) ?? false
            var untagged: [String] = []
            var deleted: [String] = []
            var errors: [String] = []
            var exitCode = 0
            for image in images {
                do {
                    let response = try await docker(LibpodAdapter.subrequest(of: req, parameter: "name", value: image))
                    for item in await LibpodAdapter.jsonBody(of: response, on: req) as? [[String: Any]] ?? [] {
                        if let tag = item["Untagged"] as? String { untagged.append(tag) }
                        if let digest = item["Deleted"] as? String { deleted.append(digest) }
                    }
                } catch let error as AbortError {
                    if ignoreMissing && error.status == .notFound { continue }
                    errors.append(error.reason)
                    exitCode = max(exitCode, LibpodSchema.imageRemoveExitCode(for: error.status.code))
                }
            }
            return try LibpodAdapter.jsonResponse(LibpodSchema.imageRemoveReport(untagged: untagged, deleted: deleted, errors: errors, exitCode: exitCode))
        }
    }

    static func singleHandler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        LibpodAdapter.reshaping(ImageDeleteRoute.handler(client: client)) { body, _ in
            var untagged: [String] = []
            var deleted: [String] = []
            for item in body as? [[String: Any]] ?? [] {
                if let tag = item["Untagged"] as? String { untagged.append(tag) }
                if let digest = item["Deleted"] as? String { deleted.append(digest) }
            }
            return LibpodSchema.imageRemoveReport(untagged: untagged, deleted: deleted, errors: [], exitCode: 0)
        }
    }
}
