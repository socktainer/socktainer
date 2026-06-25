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

            // Containers started with a TTY produce a raw, unmultiplexed log
            // stream; non-TTY containers use Docker's 8-byte stdcopy framing.
            // The docker CLI decides how to read the stream from the container's
            // Tty setting, so the framing here must match it.
            let isTTY = container.configuration.initProcess.terminal

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
                            buffer = try ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: isTTY) { outputBuffer in
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
                    follow: while true {
                        var gotData = false
                        var frames: [ByteBuffer] = []
                        do {
                            while let data = try fileHandle.read(upToCount: 4096), !data.isEmpty {
                                gotData = true
                                buffer.append(data)
                                buffer = try ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: isTTY) { outputBuffer in
                                    frames.append(outputBuffer)
                                }
                            }
                        } catch {
                            break
                        }
                        // Await each write so a client disconnect (the write future
                        // fails once the channel is closed) ends this task promptly
                        // instead of polling on until the container stops.
                        for frame in frames {
                            do {
                                try await writer.write(.buffer(frame)).get()
                            } catch {
                                break follow
                            }
                        }
                        if !gotData {
                            let current = try? await logFollowClient.get(id: container.id)
                            if current == nil || current?.status != .running { break }
                            try? await Task.sleep(for: .milliseconds(150))
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

    static func processDockerLogFrames(from buffer: Data, ttyMode: Bool, writeOutput: (ByteBuffer) -> Void) throws -> Data {
        guard !buffer.isEmpty else {
            return buffer
        }

        // Match the container's TTY mode: a TTY produces a raw, unmultiplexed
        // stream, while non-TTY logs use Docker's 8-byte stdcopy framing. Shared
        // with the attach/exec routes via writeDockerFrame so the wire format is
        // defined in exactly one place.
        var outputBuffer = ByteBufferAllocator().buffer(capacity: buffer.count + (ttyMode ? 0 : 8))
        outputBuffer.writeDockerFrame(streamType: .stdout, data: buffer, ttyMode: ttyMode)
        writeOutput(outputBuffer)
        return Data()
    }
}
