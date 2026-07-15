import Foundation
import Vapor

struct ImageCreateRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/create", use: ImageCreateRoute.handler(client: client))
    }
}

struct RESTImageCreateQuery: Content {
    let fromImage: String?
    let tag: String?
    let platform: String?
    let fromSrc: String?
    let repo: String?
    let message: String?
    let changes: [String]?
}

extension ImageCreateRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTImageCreateQuery.self)
            let image = query.fromImage ?? ""

            guard !image.isEmpty else {
                return try await handleImport(req, query: query, client: client)
            }

            let tag = query.tag ?? ""
            let decodedTag = tag.removingPercentEncoding ?? tag
            let platformString = query.platform
            let platform: Platform
            if let platformString, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    let response = Response(status: .internalServerError)
                    response.headers.add(name: .contentType, value: "application/json")
                    response.body = .init(string: "{\"message\": \"Failed to parse platform\"}\n")
                    return response
                }
            } else {
                platform = currentPlatform()
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")
            let progressStream = try await client.pull(
                image: image, tag: decodedTag, platform: platform, logger: req.logger)

            let app = req.application
            // Use decodedTag (the value actually pulled) so a percent-encoded tag
            // does not produce a mismatched reference in the "pull" event.
            let pulledRef = "\(image)\(decodedTag.isEmpty ? "" : ":\(decodedTag)")"
            response.body = .init(stream: { writer in
                Task {
                    let progressId = pulledRef.split(separator: "/").last.map(String.init) ?? pulledRef
                    await DockerProgressFrame.pipe(progressStream, id: progressId, to: writer) {
                        guard let broadcaster = app.storage[EventBroadcasterKey.self] else { return }
                        // moby's pull event uses the reference as Actor.ID and the
                        // image name as the `name` attribute (no `image` key).
                        await broadcaster.broadcast(
                            DockerEvent.make(
                                type: "image", action: "pull", actorID: pulledRef,
                                attributes: ["name": image]))
                    }
                }
            })
            return response
        }
    }

    /// `docker import`: only `fromSrc=-` (the tar streamed in the request body)
    /// is implemented. A URL `fromSrc` would require fetching a remote tarball
    /// or plain file — no outbound HTTP client is wired up for that anywhere in
    /// this codebase yet, so it is rejected rather than half-implemented.
    private static func handleImport(_ req: Request, query: RESTImageCreateQuery, client: ClientImageProtocol) async throws -> Response {
        guard let fromSrc = query.fromSrc, !fromSrc.isEmpty else {
            throw Abort(.badRequest, reason: "fromImage or fromSrc is required")
        }
        guard fromSrc == "-" else {
            throw Abort(.notImplemented, reason: "docker import with a URL fromSrc is not supported; only fromSrc=- (request body) is implemented")
        }
        let repo = query.repo ?? ""
        let tag = query.tag ?? ""
        // Matches moby: repo/tag is validated before the layer reader is even set
        // up, so a bad reference is rejected without reading the request body.
        if ClientImageService.isDigestReference(repo) {
            throw Abort(.badRequest, reason: "cannot reference \(repo) by digest")
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

        guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
            throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
        }

        let bodyBuffer: ByteBuffer
        if let data = req.body.data {
            bodyBuffer = data
        } else {
            var collectedBuffer = ByteBufferAllocator().buffer(capacity: 0)
            for try await chunk in req.body {
                var chunkBuffer = chunk
                collectedBuffer.writeBuffer(&chunkBuffer)
            }
            bodyBuffer = collectedBuffer
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tarPath = tempDir.appendingPathComponent("import.tar")
        try Data(buffer: bodyBuffer).write(to: tarPath)

        // moby defaults an empty message to "Imported from <src>".
        let message = (query.message?.isEmpty ?? true) ? "Imported from \(fromSrc)" : query.message!
        let changes = query.changes ?? []

        let app = req.application
        let response = Response()
        response.headers.add(name: .contentType, value: "application/json")
        response.body = .init(stream: { writer in
            Task {
                defer { try? FileManager.default.removeItem(at: tempDir) }
                do {
                    let (_, digest) = try await client.importImage(
                        tarPath: tarPath,
                        repo: repo.isEmpty ? nil : repo,
                        tag: tag.isEmpty ? nil : tag,
                        message: message,
                        changes: changes,
                        platform: platform,
                        appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                        logger: req.logger
                    )
                    DockerProgressFrame.write(DockerProgressFrame.status(digest), to: writer)
                    _ = writer.write(.end)

                    guard let broadcaster = app.storage[EventBroadcasterKey.self] else { return }
                    // moby's import event uses the image digest as both Actor.ID and
                    // the `name` attribute — unlike pull/tag, the human-readable
                    // reference never appears in this event.
                    await broadcaster.broadcast(
                        DockerEvent.make(type: "image", action: "import", actorID: digest, attributes: ["name": digest]))
                } catch {
                    req.logger.error("Failed to import image: \(error)")
                    DockerProgressFrame.write(DockerProgressFrame.error(String(describing: error)), to: writer)
                    _ = writer.write(.end)
                }
            }
        })
        return response
    }
}
