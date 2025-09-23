import Foundation
import NIOCore
import Vapor

struct ContainerLogsRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "logs", use: ContainerLogsRoute.handler(client: client))
        // also handle without version prefix
        routes.get("containers", ":id", "logs", use: ContainerLogsRoute.handler(client: client))

    }
}

extension ContainerLogsRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            // always use the container's log, not the boot of the container
            let boot = false
            let fhs = try await container.logs()
            let fileHandle = boot ? fhs[1] : fhs[0]
            // Create a streaming body
            // `follow=1` means tail like
            let follow = (try? req.query.get(Bool.self, at: "follow")) ?? false

            let fd = fileHandle.fileDescriptor

            let body = Response.Body { writer in
                Task.detached {
                    var buffer = Data()

                    do {
                        // Read initial logs
                        while true {
                            let data = try fileHandle.read(upToCount: 4096)
                            guard let data, !data.isEmpty else { break }
                            buffer.append(data)

                            // Process complete frames from buffer
                            buffer = try ContainerLogsRoute.processDockerLogFrames(from: buffer) { outputBuffer in
                                _ = writer.write(.buffer(outputBuffer))
                            }
                        }

                        if !follow {
                            try? fileHandle.close()
                            _ = writer.write(.end)
                            return
                        }
                    } catch {
                        try? fileHandle.close()
                        _ = writer.write(.end)
                        return
                    }

                    // For follow mode, set up a DispatchSource to stream future writes
                    let source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd,
                        eventMask: .write,
                        queue: .global()
                    )

                    source.setEventHandler {
                        do {
                            while true {
                                let data = try fileHandle.read(upToCount: 4096)
                                guard let data, !data.isEmpty else { break }
                                buffer.append(data)

                                // Process complete frames from buffer
                                buffer = try ContainerLogsRoute.processDockerLogFrames(from: buffer) { outputBuffer in
                                    _ = writer.write(.buffer(outputBuffer))
                                }
                            }
                        } catch {
                            source.cancel()
                        }
                    }

                    source.setCancelHandler {
                        try? fileHandle.close()
                        _ = writer.write(.end)
                    }

                    source.resume()
                }
            }

            return Response(
                status: .ok,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: body
            )
        }
    }

    private static func processDockerLogFrames(from buffer: Data, writeOutput: (ByteBuffer) -> Void) throws -> Data {
        // Since the buffer contains raw log data, we need to format it as Docker log frames
        // with stdout stream type (0x01)
        guard !buffer.isEmpty else {
            return buffer
        }

        // Create a Docker log frame with stdout stream type
        let streamType: UInt8 = 0x01  // stdout
        let frameSize = UInt32(buffer.count)

        // Create the 8-byte header: [stream_type, 0, 0, 0, size_bytes...]
        var frame = Data(capacity: 8 + buffer.count)
        frame.append(streamType)
        frame.append(contentsOf: [0, 0, 0])  // padding
        frame.append(contentsOf: withUnsafeBytes(of: frameSize.bigEndian) { Data($0) })
        frame.append(buffer)

        // Write the complete frame
        var outputBuffer = ByteBufferAllocator().buffer(capacity: frame.count)
        outputBuffer.writeBytes(frame)
        writeOutput(outputBuffer)

        // Return empty data since we've processed all the buffer
        return Data()
    }
}
