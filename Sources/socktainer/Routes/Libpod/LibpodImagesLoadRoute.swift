import Foundation
import Vapor

/// Podman has two distinct load endpoints (confirmed against podman's own route
/// registration source, `pkg/api/server/register_images.go`):
///   - `POST /libpod/images/load` (`libpod.ImagesLoad`) — stream a tar request body, same
///     shape as Docker compat's own `/images/load`. This is what `podman load -i file.tar`
///     actually uses.
///   - `POST /libpod/local/images/load` (`libpod.ImagesLocalLoad`) — load an archive already
///     present at an absolute path on the server's own filesystem (relevant here since
///     socktainer and the podman CLI typically share a filesystem over the unix socket).
struct RESTLocalImageLoadQuery: Content {
    let path: String?
    let platform: String?
}

/// Real podman's `ImageLoadReport` (`pkg/domain/entities/types.go`) — every reference the
/// archive loaded, not a single `Id`.
struct RESTLibpodImageLoadReport: Content {
    let Names: [String]
}

struct LibpodImagesLoadRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/load", use: ImagesLoadRoute.handler(client: client))
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/local/images/load", use: LibpodImagesLoadRoute.localHandler(client: client))
    }

    static func localHandler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTLocalImageLoadQuery.self)
            guard let path = query.path, !path.isEmpty else {
                throw Abort(.badRequest, reason: "path is required")
            }
            // A server-local path, by definition, only makes sense as absolute — a relative
            // path would resolve against socktainer's own process working directory, not
            // anything the caller could have meant.
            guard path.hasPrefix("/") else {
                throw Abort(.badRequest, reason: "path must be an absolute path")
            }
            var info = stat()
            guard stat(path, &info) == 0 else {
                guard errno == ENOENT else {
                    throw Abort(.badRequest, reason: "Unable to access \(path): errno \(errno)")
                }
                throw Abort(.notFound, reason: "No such file or directory: \(path)")
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw Abort(.badRequest, reason: "path must be a regular archive file: \(path)")
            }

            let platform: Platform
            if let platformString = query.platform, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    throw Abort(.badRequest, reason: "invalid platform: \(platformString)")
                }
            } else {
                platform = currentPlatform()
            }

            guard let appSupportURL = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
            }

            let loadedImages = try await client.load(
                tarballPath: URL(fileURLWithPath: path), platform: platform, appleContainerAppSupportUrl: appSupportURL, logger: req.logger)
            guard !loadedImages.isEmpty else {
                throw Abort(.internalServerError, reason: "Archive at \(path) contained no images")
            }

            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                let digestsByReference = await client.digestsByReference()
                for image in loadedImages {
                    let actorId = digestsByReference[image] ?? image
                    await broadcaster.broadcast(
                        DockerEvent.make(type: "image", action: "load", actorID: actorId, attributes: ["name": actorId]))
                }
            }

            return try await RESTLibpodImageLoadReport(Names: loadedImages).encodeResponse(status: .ok, for: req)
        }
    }
}
