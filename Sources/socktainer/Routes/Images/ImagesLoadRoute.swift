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
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTImageLoadQuery.self)
            let quiet = query.quiet ?? false

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

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(stream: { writer in
                Task {
                    do {
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

                        guard bodyBuffer.readableBytes > 0 else {
                            DockerProgressFrame.write(DockerProgressFrame.error("Request body is required"), to: writer)
                            _ = writer.write(.end)
                            return
                        }

                        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                        defer {
                            try? FileManager.default.removeItem(at: tempDir)
                        }

                        let tarPath = tempDir.appendingPathComponent("images.tar")
                        try Data(buffer: bodyBuffer).write(to: tarPath)

                        guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                            DockerProgressFrame.write(DockerProgressFrame.error("AppleContainerAppSupportUrl not configured"), to: writer)
                            _ = writer.write(.end)
                            return
                        }

                        if !quiet {
                            DockerProgressFrame.write(DockerProgressFrame.status("Loading images from tarball"), to: writer)
                        }

                        let loadedImages = try await client.load(
                            tarballPath: tarPath, platform: platform, appleContainerAppSupportUrl: appleContainerAppSupportUrl, logger: req.logger)

                        // moby emits one "load" event per loaded image with the digest as
                        // Actor.ID (daemon/containerd/image_exporter.go). Loaded references
                        // come straight from the store, so the digest lookup normally hits;
                        // a miss falls back to the reference.
                        let broadcaster = req.application.storage[EventBroadcasterKey.self]
                        let digestsByReference = broadcaster != nil ? await client.digestsByReference() : [:]

                        for image in loadedImages {
                            if !quiet {
                                DockerProgressFrame.write(DockerProgressFrame.status("Loaded image \(image)"), to: writer)
                            }
                            DockerProgressFrame.write(DockerProgressFrame.stream("Loaded image: \(image)\n"), to: writer)
                            if let broadcaster {
                                let actorId = digestsByReference[image] ?? image
                                await broadcaster.broadcast(
                                    DockerEvent.make(
                                        type: "image", action: "load", actorID: actorId,
                                        attributes: ["name": actorId]))
                            }
                        }

                        _ = writer.write(.end)
                    } catch {
                        req.logger.error("Failed to load images: \(error)")
                        DockerProgressFrame.write(DockerProgressFrame.error(String(describing: error)), to: writer)
                        _ = writer.write(.end)
                    }
                }
            })

            return response
        }
    }
}
