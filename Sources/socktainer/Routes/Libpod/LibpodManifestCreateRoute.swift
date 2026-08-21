import ContainerPersistence
import Vapor

struct RESTManifestCreateQuery: Content {
    let images: [String]?
    let image: [String]?
    let amend: Bool?
}

struct RESTManifestCreateRequest: Content {
    let images: [String]?
}

struct RESTManifestIDResponse: Content {
    let ID: String

    // Real podman's IDResponse serializes the field as "Id", not "ID"
    // (pkg/domain/entities/types: `ID string \`json:"Id"\``).
    enum CodingKeys: String, CodingKey {
        case ID = "Id"
    }
}

struct LibpodManifestCreateRoute: RouteCollection {
    let client: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/manifests/{name:.*}", use: LibpodManifestCreateRoute.handler(client: client))
    }

    static func handler(client: ClientManifestServiceProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing manifest list name")
            }

            // Real podman's ManifestCreate accepts images via either the `image` or `images`
            // query param (repeated), or a JSON body — support both. Malformed input is a real
            // 400, not something to silently swallow into "no images requested."
            let query: RESTManifestCreateQuery
            do {
                query = try req.query.decode(RESTManifestCreateQuery.self)
            } catch {
                throw Abort(.badRequest, reason: "Invalid query parameters: \(error)")
            }
            var images = query.images ?? []
            images.append(contentsOf: query.image ?? [])

            // Real podman's client (matching `LibpodManifestModifyRoute`'s own documented
            // behavior for the same family of endpoints) can send a JSON body WITHOUT a
            // `Content-Type` header — `req.content.decode` unconditionally fails against
            // that ("Can't decode data without a content type"), regardless of whether the
            // body itself is well-formed. Decode the raw bytes directly with `JSONDecoder`
            // in that case instead of skipping the body entirely — a manifest create with
            // no query images and all its data in a Content-Type-less body must still see
            // that data, not silently proceed as if no images were requested. A
            // malformed/undecodable body still shouldn't fail a request that already has
            // everything it needs via the `image`/`images` query params.
            let bodyBytes = req.body.data
            if let bodyBytes, bodyBytes.readableBytes > 0 {
                do {
                    let body: RESTManifestCreateRequest
                    if req.headers.contentType != nil {
                        body = try req.content.decode(RESTManifestCreateRequest.self)
                    } else {
                        body = try JSONDecoder().decode(RESTManifestCreateRequest.self, from: Data(buffer: bodyBytes))
                    }
                    images.append(contentsOf: body.images ?? [])
                } catch {
                    guard !images.isEmpty else {
                        throw Abort(.badRequest, reason: "Invalid request body: \(error)")
                    }
                }
            }

            do {
                let digest = try await client.create(name: name, images: images, logger: req.logger, amend: query.amend ?? false)
                // Real podman's ManifestCreate returns 201 Created for API versions >= 4.0.0
                // (only pre-4.0 clients get 200 OK) — this daemon always reports a modern
                // libpod API version (see LibpodVersionRoute), so 201 is always correct here.
                return try await RESTManifestIDResponse(ID: digest).encodeResponse(status: .created, for: req)
            } catch ClientImageError.notFound(let id) {
                throw Abort(.badRequest, reason: "No such image: \(id)")
            } catch ClientManifestError.alreadyExists {
                throw Abort(.conflict, reason: "manifest list \(name) already exists (use --amend to update it)")
            }
        }
    }
}
