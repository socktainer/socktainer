import Vapor

struct LibpodImagesGetRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/export", use: LibpodImagesGetRoute.handlerMultiple(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/{name:.*}/get", use: ImagesGetRoute.handlerSingle(client: client))
    }

    /// Real podman's multi-image export endpoint is `GET /libpod/images/export`
    /// (`libpod.ExportImages`, confirmed against `pkg/api/server/register_images.go`), decoding
    /// a repeated `references` query param — not Docker-compat's `/images/get?names=...`.
    static func handlerMultiple(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let references = try? req.query.get([String].self, at: "references")

            guard let references, !references.isEmpty else {
                throw Abort(.badRequest, reason: "At least one image name is required in 'references' query parameter")
            }

            return try await ImagesGetRoute.saveImages(references: references, req: req, client: client)
        }
    }
}
