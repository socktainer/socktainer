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
                    let response = Response(status: .badRequest)
                    response.headers.add(name: .contentType, value: "application/json")
                    response.body = .init(string: "{\"message\": \"Failed to parse platform\"}\n")
                    return response
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
                            _ = writer.write(.buffer(ByteBuffer(string: "{\"message\": \"Request body is required\"}\n")))
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
                            _ = writer.write(.buffer(ByteBuffer(string: "{\"error\": \"AppleContainerAppSupportUrl not configured\"}\n")))
                            _ = writer.write(.end)
                            return
                        }

                        if !quiet {
                            _ = writer.write(.buffer(ByteBuffer(string: "{\"status\": \"Loading images from tarball\"}\n")))
                        }

                        let loadedImages = try await client.load(
                            tarballPath: tarPath, platform: platform, appleContainerAppSupportUrl: appleContainerAppSupportUrl, logger: req.logger)

                        for image in loadedImages {
                            if !quiet {
                                _ = writer.write(.buffer(ByteBuffer(string: "{\"status\": \"Loaded image \(image)\"}\n")))
                            }
                            _ = writer.write(.buffer(ByteBuffer(string: "{\"stream\": \"Loaded image: \(image)\"}\n")))
                        }

                        _ = writer.write(.end)
                    } catch {
                        req.logger.error("Failed to load images: \(error)")
                        _ = writer.write(.buffer(ByteBuffer(string: "{\"error\": \"\(error.localizedDescription)\"}\n")))
                        _ = writer.write(.error(error))
                    }
                }
            })

            return response
        }
    }
}
