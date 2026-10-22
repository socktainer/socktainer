import Foundation
import Vapor

/// Podman's libpod import (`/libpod/images/import`) uses a `reference` query
/// param (`Name[:TAG]`) instead of Docker compat's split `repo`/`tag` pair.
/// Only the streamed-body form (no remote `url`) is supported, matching the
/// existing Docker-side `ImageCreateRoute` import path.
///
/// Unlike Docker compat's `/images/create` (a chunked progress stream), real
/// podman's `ImagesImport` handler (`pkg/api/handlers/libpod/images.go`)
/// writes a single JSON object, `entities.ImageImportReport{ Id string }`,
/// once the import completes — so this calls `client.importImage` directly
/// rather than delegating to and forwarding the Docker route's streaming
/// response, which real podman clients don't know how to parse.
struct LibpodImageImportRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/import", use: LibpodImageImportRoute.handler(client: client))
    }

    struct LibpodImageImportQuery: Content {
        let reference: String?
        let message: String?
        let url: String?
        let changes: [String]?
    }

    struct RESTLibpodImportIDResponse: Content {
        let Id: String
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(LibpodImageImportQuery.self)

            guard query.url == nil || query.url!.isEmpty else {
                throw Abort(.notImplemented, reason: "podman import from a remote URL is not supported; only a streamed tarball body is implemented")
            }

            let (repo, tag) = splitReference(query.reference ?? "")
            switch ClientImageService.validateImportReference(repo: repo, tag: tag) {
            case .valid:
                break
            case .digestNotAllowed:
                throw Abort(.badRequest, reason: "cannot reference \(repo) by digest")
            case .malformed(let reason):
                throw Abort(.badRequest, reason: "invalid reference format: \(reason)")
            }

            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tarPath = tempDir.appendingPathComponent("import.tar")
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try await ImageCreateRoute.writeBodyToFile(req.body, at: tarPath)

            // podman defaults an empty message to "Imported from <src>", same as moby.
            let message = (query.message?.isEmpty ?? true) ? "Imported from -" : query.message!

            let digest: String
            do {
                (_, digest) = try await client.importImage(
                    tarPath: tarPath,
                    repo: repo.isEmpty ? nil : repo,
                    tag: tag.isEmpty ? nil : tag,
                    message: message,
                    changes: query.changes ?? [],
                    platform: currentPlatform(),
                    appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                    logger: req.logger
                )
            } catch {
                throw Abort(.internalServerError, reason: "Failed to import image: \(error)")
            }

            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // moby's import event uses the image digest as both Actor.ID and the
                // `name` attribute — unlike pull/tag, the human-readable reference never
                // appears in this event. Mirrors ImageCreateRoute's own import event.
                await broadcaster.broadcast(
                    DockerEvent.make(type: "image", action: "import", actorID: digest, attributes: ["name": digest]))
            }

            return try await RESTLibpodImportIDResponse(Id: digest).encodeResponse(status: .ok, for: req)
        }
    }

    private static func splitReference(_ reference: String) -> (repo: String, tag: String) {
        guard !reference.isEmpty else { return ("", "") }
        // A digest reference (name@sha256:...) has no tag component — the colon inside
        // the digest is not a tag separator.
        if reference.contains("@") { return (reference, "") }
        if let colonIndex = reference.lastIndex(of: ":"), !reference[colonIndex...].contains("/") {
            let repo = String(reference[..<colonIndex])
            let tag = String(reference[reference.index(after: colonIndex)...])
            return (repo, tag)
        }
        return (reference, "")
    }
}
