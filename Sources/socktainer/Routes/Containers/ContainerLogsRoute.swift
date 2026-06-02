import ContainerAPIClient
import Foundation
import NIOCore
import Vapor

struct ContainerLogsRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/logs", use: ContainerLogsRoute.handler(client: client))
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
            let fhs = try await ContainerClient().logs(id: container.id)
            let fileHandle = boot ? fhs[1] : fhs[0]
            // Create a streaming body
            // `follow=1` means tail like
            let follow = (try? req.query.get(Bool.self, at: "follow")) ?? false

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

                    // For follow mode, poll the log file for new writes. A
                    // DispatchSource on the log fd is fragile: it can fire on a
                    // closed/invalidated fd during teardown (container removed or
                    // client disconnect) and crash the whole process with a
                    // libdispatch trap. Polling is robust. Exit once the
                    // container is no longer running.
                    let logFollowClient = ContainerClient()
                    while true {
                        var gotData = false
                        do {
                            while let data = try fileHandle.read(upToCount: 4096), !data.isEmpty {
                                gotData = true
                                buffer.append(data)
                                buffer = try ContainerLogsRoute.processDockerLogFrames(from: buffer) { outputBuffer in
                                    _ = writer.write(.buffer(outputBuffer))
                                }
                            }
                        } catch {
                            break
                        }
                        if !gotData {
                            let current = try? await logFollowClient.get(id: container.id)
                            if current == nil || current?.status != .running { break }
                            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
                        }
                    }
                    try? fileHandle.close()
                    _ = writer.write(.end)
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
