import Foundation
import Vapor

struct ImagesLoadRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/load", use: ImagesLoadRoute.handler(client: client))
    }
}

struct RESTImageLoadQuery: Content {
    let quiet: Bool?
    let platform: String?
}

extension ImagesLoadRoute {
    /// Docker image archives can contain many platforms and legitimately reach
    /// tens of gigabytes. Keep a generous disk-backed bound while preventing an
    /// unbounded upload from filling the host volume.
    private static let maxLoadBodySize = 64 * 1024 * 1024 * 1024

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTImageLoadQuery.self)
            let quiet = query.quiet ?? false

            let platform: Platform?
            if let platformString = query.platform, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    throw Abort(.badRequest, reason: "invalid platform: \(platformString)")
                }
            } else {
                platform = nil
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")

            let body = req.body
            let appleContainerAppSupportURL =
                req.application.storage[AppleContainerAppSupportUrlKey.self]
            let broadcaster =
                req.application.storage[EventBroadcasterKey.self]
            let logger = req.logger
            response.body = .init(managedAsyncStream: { writer in
                try await produceLoadResponse(
                    body: body,
                    quiet: quiet,
                    platform: platform,
                    appleContainerAppSupportURL:
                        appleContainerAppSupportURL,
                    client: client,
                    broadcaster: broadcaster,
                    writer: writer,
                    logger: logger
                )
            })

            return response
        }
    }

    static func produceLoadResponse<Chunks>(
        body: Chunks,
        quiet: Bool,
        platform: Platform?,
        appleContainerAppSupportURL: URL?,
        client: any ClientImageProtocol,
        broadcaster: EventBroadcaster?,
        writer: any AsyncBodyStreamWriter,
        logger: Logger,
        temporaryDirectoryParent: URL =
            FileManager.default.temporaryDirectory,
        heartbeatInterval: Duration =
            DisconnectCoupledResponseStream.defaultHeartbeatInterval
    ) async throws
    where
        Chunks: AsyncSequence & Sendable,
        Chunks.Element == ByteBuffer
    {
        do {
            try await DisconnectCoupledResponseStream.run(
                writer: writer,
                heartbeatInterval: heartbeatInterval
            ) { writer in
                do {
                    let tempDir =
                        try RequestBodyFileWriter
                        .createSecureTemporaryDirectory(
                            in: temporaryDirectoryParent
                        )
                    defer {
                        try? FileManager.default.removeItem(at: tempDir)
                    }

                    let tarPath = tempDir.appendingPathComponent("images.tar")
                    let bodySize = try await RequestBodyFileWriter.write(
                        body,
                        to: tarPath,
                        maxBytes: maxLoadBodySize,
                        kind: "image load body"
                    )
                    guard bodySize > 0 else {
                        try await DockerProgressFrame.write(
                            DockerProgressFrame.error(
                                "Request body is required"
                            ),
                            to: writer
                        )
                        return
                    }
                    guard let appleContainerAppSupportURL else {
                        try await DockerProgressFrame.write(
                            DockerProgressFrame.error(
                                "AppleContainerAppSupportUrl not configured"
                            ),
                            to: writer
                        )
                        return
                    }

                    if !quiet {
                        try await DockerProgressFrame.write(
                            DockerProgressFrame.status(
                                "Loading images from tarball"
                            ),
                            to: writer
                        )
                    }

                    let loadedImages: [String]
                    let actorIDs: [String]
                    if let identityLoadingClient =
                        client as? any ImageLoadingWithIdentity
                    {
                        let loaded =
                            try await identityLoadingClient
                            .loadWithIdentities(
                                tarballPath: tarPath,
                                platform: platform,
                                appleContainerAppSupportUrl:
                                    appleContainerAppSupportURL,
                                logger: logger
                            )
                        loadedImages = loaded.references
                        actorIDs = loaded.actorIDs
                    } else {
                        loadedImages = try await client.load(
                            tarballPath: tarPath,
                            platform: platform,
                            appleContainerAppSupportUrl:
                                appleContainerAppSupportURL,
                            logger: logger
                        )
                        // Compatibility path for injected clients predating the
                        // atomic load identity boundary.
                        let digestsByReference =
                            broadcaster != nil
                            ? await client.digestsByReference() : [:]
                        actorIDs = loadedImages.map {
                            digestsByReference[$0] ?? $0
                        }
                    }

                    for (offset, image) in loadedImages.enumerated() {
                        if !quiet {
                            try await DockerProgressFrame.write(
                                DockerProgressFrame.status(
                                    "Loaded image \(image)"
                                ),
                                to: writer
                            )
                        }
                        try await DockerProgressFrame.write(
                            DockerProgressFrame.stream(
                                "Loaded image: \(image)\n"
                            ),
                            to: writer
                        )
                        if let broadcaster {
                            let actorId =
                                actorIDs.indices.contains(offset)
                                ? actorIDs[offset] : image
                            await broadcaster.broadcast(
                                DockerEvent.make(
                                    type: "image",
                                    action: "load",
                                    actorID: actorId,
                                    attributes: ["name": actorId]
                                )
                            )
                        }
                    }
                } catch DisconnectCoupledResponseStream.ProducerError
                    .clientDisconnected
                {
                    throw DisconnectCoupledResponseStream.ProducerError
                        .clientDisconnected
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error("Failed to load images: \(error)")
                    try await DockerProgressFrame.write(
                        DockerProgressFrame.error(String(describing: error)),
                        to: writer
                    )
                }
            }
        } catch DisconnectCoupledResponseStream.ProducerError.clientDisconnected {
            logger.debug("Image load client disconnected; cancelling load")
            throw CancellationError()
        }
    }
}
