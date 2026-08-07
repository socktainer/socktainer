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
            let fallbackPolicy: PlatformFallbackPolicy
            if let platformString, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    throw Abort(
                        .badRequest,
                        reason: "invalid platform: \(platformString)"
                    )
                }
                fallbackPolicy = .strict
            } else {
                platform = currentPlatform()
                fallbackPolicy = .allowRosetta
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")
            let progressStream = try await client.pull(
                image: image,
                tag: decodedTag,
                platform: platform,
                fallbackPolicy: fallbackPolicy,
                logger: req.logger
            )

            let app = req.application
            // Use decodedTag (the value actually pulled) so a percent-encoded tag
            // does not produce a mismatched reference in the "pull" event.
            let pulledRef = "\(image)\(decodedTag.isEmpty ? "" : ":\(decodedTag)")"
            let logger = req.logger
            response.body = .init(managedAsyncStream: { writer in
                let progressId =
                    pulledRef.split(separator: "/").last.map(String.init)
                    ?? pulledRef
                try await producePullResponse(
                    progressStream,
                    progressID: progressId,
                    writer: writer,
                    logger: logger
                ) {
                    guard let broadcaster = app.storage[EventBroadcasterKey.self] else { return }
                    // moby's pull event uses the reference as Actor.ID and the
                    // image name as the `name` attribute (no `image` key).
                    await broadcaster.broadcast(
                        DockerEvent.make(
                            type: "image", action: "pull", actorID: pulledRef,
                            attributes: ["name": image]))
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
        // up, so any malformed reference — not just a digest — is rejected
        // without reading the request body.
        switch ClientImageService.validateImportReference(repo: repo, tag: tag) {
        case .valid:
            break
        case .digestNotAllowed:
            throw Abort(.badRequest, reason: "cannot reference \(repo) by digest")
        case .malformed(let reason):
            throw Abort(.badRequest, reason: "invalid reference format: \(reason)")
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

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tarPath = tempDir.appendingPathComponent("import.tar")
        do {
            try await RequestBodyFileWriter.write(
                req.body,
                to: tarPath,
                maxBytes: maxImportBodySize,
                kind: "import body"
            )
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }

        // moby defaults an empty message to "Imported from <src>".
        let message =
            query.message.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Imported from \(fromSrc)"
        let changes = query.changes ?? []

        let app = req.application
        let response = Response()
        response.headers.add(name: .contentType, value: "application/json")
        let logger = req.logger
        response.body = .init(managedAsyncStream: { writer in
            try await produceImportResponse(
                temporaryDirectory: tempDir,
                writer: writer,
                logger: logger
            ) { writer in
                let (_, digest) = try await client.importImage(
                    tarPath: tarPath,
                    repo: repo.isEmpty ? nil : repo,
                    tag: tag.isEmpty ? nil : tag,
                    message: message,
                    changes: changes,
                    platform: platform,
                    appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                    logger: logger
                )
                try await DockerProgressFrame.write(
                    DockerProgressFrame.status(digest),
                    to: writer
                )

                guard let broadcaster = app.storage[EventBroadcasterKey.self] else { return }
                // moby's import event uses the image digest as both Actor.ID and
                // the `name` attribute — unlike pull/tag, the human-readable
                // reference never appears in this event.
                await broadcaster.broadcast(
                    DockerEvent.make(type: "image", action: "import", actorID: digest, attributes: ["name": digest]))
            }
        })
        return response
    }

    /// Import bodies are single-layer tarballs and can legitimately be several
    /// GB; this bounds them well above any real use while still rejecting a
    /// runaway or malicious upload before it fills disk.
    private static let maxImportBodySize = 8 * 1024 * 1024 * 1024

    static func producePullResponse(
        _ progress: AsyncThrowingStream<PullProgress, Error>,
        progressID: String,
        writer: any AsyncBodyStreamWriter,
        logger: Logger,
        heartbeatInterval: Duration =
            DisconnectCoupledResponseStream.defaultHeartbeatInterval,
        onSuccess: (@Sendable () async -> Void)? = nil
    ) async throws {
        do {
            try await DisconnectCoupledResponseStream.run(
                writer: writer,
                heartbeatInterval: heartbeatInterval
            ) { writer in
                try await DockerProgressFrame.pipe(
                    progress,
                    id: progressID,
                    to: writer,
                    onSuccess: onSuccess
                )
            }
        } catch DisconnectCoupledResponseStream.ProducerError.clientDisconnected {
            logger.debug("Image pull client disconnected; cancelling pull")
            throw CancellationError()
        }
    }

    static func produceImportResponse(
        temporaryDirectory: URL,
        writer: any AsyncBodyStreamWriter,
        logger: Logger,
        heartbeatInterval: Duration =
            DisconnectCoupledResponseStream.defaultHeartbeatInterval,
        operation:
            @Sendable @escaping (
                any AsyncBodyStreamWriter
            ) async throws -> Void
    ) async throws {
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        do {
            try await DisconnectCoupledResponseStream.run(
                writer: writer,
                heartbeatInterval: heartbeatInterval
            ) { writer in
                do {
                    try await operation(writer)
                } catch DisconnectCoupledResponseStream.ProducerError
                    .clientDisconnected
                {
                    throw DisconnectCoupledResponseStream.ProducerError
                        .clientDisconnected
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error("Failed to import image: \(error)")
                    try await DockerProgressFrame.write(
                        DockerProgressFrame.error(String(describing: error)),
                        to: writer
                    )
                }
            }
        } catch DisconnectCoupledResponseStream.ProducerError.clientDisconnected {
            logger.debug("Image import client disconnected; cancelling import")
            throw CancellationError()
        }
    }

}
