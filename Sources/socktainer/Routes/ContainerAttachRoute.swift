import ContainerClient
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

private struct ContainerAttachQuery: Content {
    let logs: Bool?
    let stream: Bool?
    let stdin: Bool?
    let stdout: Bool?
    let stderr: Bool?
    let detachKeys: String?
}

struct ContainerAttachRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/attach", use: ContainerAttachRoute.handler(client: client))
    }
}

extension ContainerAttachRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            // TODO: This should be refactored to some generic implementation that is shared
            //       with /containers/{id}/exec route.
            let connectionHeader = req.headers.first(name: "Connection")?.lowercased()
            let upgradeHeader = req.headers.first(name: "Upgrade")?.lowercased()
            let shouldUpgradeToTCP = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp"

            let response = try await handleAttachRequest(req: req, client: client)

            // If client requested upgrade and handler returned OK,
            // convert to 101 Switching Protocols
            if shouldUpgradeToTCP && response.status == .ok {
                var hijackedHeaders: HTTPHeaders = [:]
                hijackedHeaders.add(name: "Connection", value: "Upgrade")
                hijackedHeaders.add(name: "Upgrade", value: "tcp")

                return Response(
                    status: .switchingProtocols,
                    headers: hijackedHeaders,
                    body: response.body
                )
            }

            return response
        }
    }

    private static func handleAttachRequest(req: Request, client: ClientContainerProtocol) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing container ID")
        }

        let query = try req.query.decode(ContainerAttachQuery.self)

        let logs = query.logs ?? false
        let stream = query.stream ?? false
        let stdin = query.stdin ?? false
        let stdout = query.stdout ?? false
        let stderr = query.stderr ?? false
        // NOTE: Not currently implemented, we use the default keys
        let _ = query.detachKeys ?? "ctrl-c,ctrl-p"

        // NOTE: We currently do not implement this mechanism
        //       as in Docker CLI
        guard stream || logs else {
            throw Abort(.badRequest, reason: "Either the stream or logs parameter must be true")
        }

        // If no stdout/stderr specified, default to both (Docker behavior)
        guard stdout || stderr || (!stdout && !stderr) else {
            throw Abort(.badRequest, reason: "At least one of stdout or stderr must be true")
        }

        guard let container = try await client.getContainer(id: id) else {
            throw Abort(.notFound, reason: "No such container: \(id)")
        }

        // hijack connection
        let isUpgrade = req.headers.contains(where: { $0.name.lowercased() == "upgrade" && $0.value.lowercased() == "tcp" })
        let hasConnectionUpgrade = req.headers.contains(where: { $0.name.lowercased() == "connection" && $0.value.lowercased().contains("upgrade") })

        let isTTY = container.configuration.initProcess.terminal

        // NOTE: When stdin is true, we will start the container before the client
        //       this might be a workaround for the time being.
        //       We are interested in having access to stdin file descriptor from the start
        if stdin {
            return try await handleAttachWithStdin(
                req: req,
                client: client,
                container: container,
                query: query,
                isUpgrade: isUpgrade,
                hasConnectionUpgrade: hasConnectionUpgrade,
                isTTY: isTTY
            )
        }

        // Set appropriate content type based on TTY mode
        let contentType = isTTY ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)

        if isUpgrade && hasConnectionUpgrade {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
        }

        // Create streaming response body using container logs when not using stdin
        let body = Response.Body { writer in
            Task.detached {
                let pollInterval: UInt64 = 200_000_000  // 200ms
                var containerWasRunning = false

                // Continuously poll for log handles and send data
                while true {
                    // Check if container still exists
                    do {
                        _ = try await client.getContainer(id: id)
                    } catch {
                        break
                    }

                    var logHandles: [FileHandle] = []
                    var hasValidHandles = false

                    // Try to get log handles
                    do {
                        logHandles = try await container.logs()
                        hasValidHandles = !logHandles.isEmpty

                    } catch {
                        hasValidHandles = false
                    }

                    if hasValidHandles {
                        let shouldAttachStdout = stdout || (!stdout && !stderr)

                        var consecutiveEmptyReads = 0
                        let maxEmptyReads = 100  // Switch to polling after 100 empty reads

                        while true {
                            // Check if container still exists before reading data
                            // Check if container is still running (only exit if it was running and now stopped)
                            do {
                                let currentContainer = try await client.getContainer(id: id)
                                guard let container = currentContainer else {
                                    _ = writer.write(.end)
                                    return
                                }
                                if container.status == .running {
                                    containerWasRunning = true
                                } else if containerWasRunning {
                                    // Container was running but now stopped - exit
                                    _ = writer.write(.end)
                                    return
                                }
                            } catch {
                                // Container not available, break out of both loops
                                _ = writer.write(.end)
                                return
                            }

                            var hasData = false

                            if shouldAttachStdout && logHandles.indices.contains(0) {
                                let stdoutData = logHandles[0].availableData
                                if !stdoutData.isEmpty {
                                    hasData = true
                                    var buffer = ByteBufferAllocator().buffer(capacity: stdoutData.count + (isTTY ? 0 : 8))
                                    buffer.writeDockerFrame(streamType: .stdout, data: stdoutData, ttyMode: isTTY)
                                    _ = writer.write(.buffer(buffer))
                                }
                            }

                            if !hasData {
                                consecutiveEmptyReads += 1

                                // After many empty reads, send empty data to keep connection alive
                                if consecutiveEmptyReads >= maxEmptyReads {
                                    let keepAliveData = Data()
                                    var buffer = ByteBufferAllocator().buffer(capacity: (isTTY ? 0 : 8))
                                    buffer.writeDockerFrame(streamType: .stdout, data: keepAliveData, ttyMode: isTTY)
                                    _ = writer.write(.buffer(buffer))
                                    consecutiveEmptyReads = 0  // Reset counter

                                    try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
                                } else {
                                    try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                                }
                            } else {
                                // Reset empty read counter when we get data
                                consecutiveEmptyReads = 0
                            }
                        }

                    } else {
                        // No valid handles, send empty data to keep connection alive
                        let keepAliveData = Data()

                        var buffer = ByteBufferAllocator().buffer(capacity: (isTTY ? 0 : 8))
                        buffer.writeDockerFrame(streamType: .stdout, data: keepAliveData, ttyMode: isTTY)

                        _ = writer.write(.buffer(buffer))
                    }

                    do {
                        try await Task.sleep(nanoseconds: pollInterval)
                    } catch {
                        break
                    }
                }

                _ = writer.write(.end)
            }
        }

        let status: HTTPResponseStatus = (isUpgrade && hasConnectionUpgrade) ? .switchingProtocols : .ok

        return Response(
            status: status,
            headers: headers,
            body: body
        )
    }

    private static func handleAttachWithStdin(
        req: Request,
        client: ClientContainerProtocol,
        container: ClientContainer,
        query: ContainerAttachQuery,
        isUpgrade: Bool,
        hasConnectionUpgrade: Bool,
        isTTY: Bool
    ) async throws -> Response {

        let connectionHeader = req.headers.first(name: "Connection")?.lowercased()
        let upgradeHeader = req.headers.first(name: "Upgrade")?.lowercased()
        let shouldUpgrade = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp"

        guard let currentContainer = try await client.getContainer(id: container.id) else {
            throw Abort(.notFound, reason: "Container not found")
        }

        // NOTE: For true docker run -it behavior, we need to control the main process stdio,
        //       this means we need to bootstrap the container with our own pipes
        guard currentContainer.status == .stopped else {
            throw Abort(.conflict, reason: "Container is in \(currentContainer.status) state and cannot be attached to")
        }
        return try await createContainerForAttachment(
            req: req,
            client: client,
            container: currentContainer,
            query: query,
            shouldUpgrade: shouldUpgrade,
            isTTY: isTTY
        )
    }

    // Handle attachment to stopped containers by bootstrapping with our stdio
    private static func createContainerForAttachment(
        req: Request,
        client: ClientContainerProtocol,
        container: ClientContainer,
        query: ContainerAttachQuery,
        shouldUpgrade: Bool,
        isTTY: Bool
    ) async throws -> Response {

        let attachStdout = query.stdout ?? true
        let attachStderr = query.stderr ?? !isTTY

        // Create pipes for bidirectional communication with the main process
        let stdinPipe: Pipe = Pipe()
        let stdoutPipe: Pipe? = attachStdout ? Pipe() : nil
        let stderrPipe: Pipe? = (attachStderr && !isTTY) ? Pipe() : nil

        let stdio = [
            stdinPipe.fileHandleForReading,
            stdoutPipe?.fileHandleForWriting,
            stderrPipe?.fileHandleForWriting,
        ]

        let process: ClientProcess
        do {
            process = try await container.bootstrap(stdio: stdio)
        } catch {
            throw Abort(.internalServerError, reason: "Failed to bootstrap container: \(error.localizedDescription)")
        }

        do {
            try await process.start()
        } catch {
            throw Abort(.internalServerError, reason: "Failed to start main process: \(error.localizedDescription)")
        }

        guard shouldUpgrade else {

            return ConnectionHijackingMiddleware.createDockerStreamingResponse(
                request: req,
                ttyEnabled: isTTY
            ) { streamContinuation in
                await withTaskGroup(of: Void.self) { group in
                    // Process monitor - when process exits, close pipes and finish stream
                    group.addTask {
                        do {
                            let _ = try await process.wait()
                        } catch {
                        }

                        // Close pipes to break the reader loops
                        try? stdoutPipe?.fileHandleForWriting.close()
                        try? stderrPipe?.fileHandleForWriting.close()
                        try? stdinPipe.fileHandleForWriting.close()

                        // Close stream
                        streamContinuation.finish()
                    }

                    if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                        group.addTask {
                            while true {
                                do {
                                    guard let data = try stdoutHandle.read(upToCount: 4096), !data.isEmpty else {
                                        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                                        continue
                                    }

                                    var buffer = ByteBufferAllocator().buffer(capacity: data.count + (isTTY ? 0 : 8))
                                    buffer.writeDockerFrame(streamType: .stdout, data: data, ttyMode: isTTY)
                                    streamContinuation.yield(buffer)
                                } catch {
                                    break
                                }
                            }
                            try? stdoutHandle.close()
                        }
                    }

                    if let stderrHandle = stderrPipe?.fileHandleForReading {
                        group.addTask {
                            while true {
                                do {
                                    guard let data = try stderrHandle.read(upToCount: 4096), !data.isEmpty else {
                                        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                                        continue
                                    }

                                    var buffer = ByteBufferAllocator().buffer(capacity: data.count + 8)
                                    buffer.writeDockerFrame(streamType: .stderr, data: data, ttyMode: isTTY)
                                    streamContinuation.yield(buffer)
                                } catch {
                                    break
                                }
                            }
                            try? stderrHandle.close()
                        }
                    }

                    let stdinWriter = stdinPipe.fileHandleForWriting
                    group.addTask {
                        do {
                            for try await var buf in req.body {
                                if let data = buf.readData(length: buf.readableBytes) {
                                    try stdinWriter.write(contentsOf: data)
                                    try stdinWriter.synchronize()
                                }
                            }
                        } catch {
                        }
                        try? stdinWriter.close()
                    }

                    for await _ in group {}
                }
            }
        }

        return Response.dockerTCPUpgrade(
            execId: container.id,
            ttyEnabled: isTTY
        ) { channel, tcpHandler in

            tcpHandler.setStdinWriter(stdinPipe.fileHandleForWriting)

            await withTaskGroup(of: Void.self) { group in
                if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                    group.addTask {
                        let dispatchIO = DispatchIO(
                            type: .stream,
                            fileDescriptor: stdoutHandle.fileDescriptor,
                            queue: DispatchQueue.global(qos: .userInteractive)
                        ) { error in
                        }

                        dispatchIO.setLimit(lowWater: 1)
                        dispatchIO.setLimit(highWater: 4096)

                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            var isFinished = false
                            var hasResumed = false

                            func readNextChunk() {
                                guard !isFinished else { return }

                                dispatchIO.read(
                                    offset: off_t.max,
                                    length: 4096,
                                    queue: DispatchQueue.global(qos: .userInteractive)
                                ) { done, data, error in
                                    if let data = data, !data.isEmpty {
                                        channel.eventLoop.execute {
                                            var outputBuffer = channel.allocator.buffer(capacity: data.count + (isTTY ? 0 : 8))
                                            if isTTY {
                                                outputBuffer.writeBytes(data)
                                            } else {
                                                outputBuffer.writeDockerFrame(streamType: .stdout, data: Data(data), ttyMode: false)
                                            }
                                            _ = channel.writeAndFlush(outputBuffer)
                                        }
                                    }

                                    if done || error != 0 {
                                        if !isFinished && !hasResumed {
                                            isFinished = true
                                            hasResumed = true
                                            dispatchIO.close()
                                            continuation.resume()
                                        }
                                    } else if !isFinished {
                                        readNextChunk()
                                    }
                                }
                            }

                            readNextChunk()
                        }

                        try? stdoutHandle.close()
                    }
                }

                if let stderrHandle = stderrPipe?.fileHandleForReading {
                    group.addTask {
                        let dispatchIO = DispatchIO(
                            type: .stream,
                            fileDescriptor: stderrHandle.fileDescriptor,
                            queue: DispatchQueue.global(qos: .userInteractive)
                        ) { error in
                        }

                        dispatchIO.setLimit(lowWater: 1)
                        dispatchIO.setLimit(highWater: 1024)

                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            var isFinished = false
                            var hasResumed = false

                            func readNextChunk() {
                                guard !isFinished else { return }

                                dispatchIO.read(
                                    offset: off_t.max,
                                    length: 1024,
                                    queue: DispatchQueue.global(qos: .userInteractive)
                                ) { done, data, error in
                                    if let data = data, !data.isEmpty {
                                        channel.eventLoop.execute {
                                            var outputBuffer = channel.allocator.buffer(capacity: data.count + 8)
                                            outputBuffer.writeDockerFrame(streamType: .stderr, data: Data(data), ttyMode: isTTY)
                                            _ = channel.writeAndFlush(outputBuffer)
                                        }
                                    }

                                    if done || error != 0 {
                                        if !isFinished && !hasResumed {
                                            isFinished = true
                                            hasResumed = true
                                            dispatchIO.close()
                                            continuation.resume()
                                        }
                                    } else if !isFinished {
                                        readNextChunk()
                                    }
                                }
                            }

                            readNextChunk()
                        }

                        try? stderrHandle.close()
                    }
                }

                group.addTask {
                    while channel.isActive {
                        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                    }
                }

                group.addTask {
                    do {
                        let _ = try await process.wait()
                    } catch {
                    }

                    // Give a small delay for any final output to be processed
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

                    // Close all pipes to signal EOF to readers
                    try? stdoutPipe?.fileHandleForWriting.close()
                    try? stderrPipe?.fileHandleForWriting.close()
                    try? stdinPipe.fileHandleForWriting.close()

                    // Close the channel gracefully
                    _ = channel.eventLoop.submit {
                        channel.close(promise: nil)
                    }
                }

                for await _ in group {}
            }
        }
    }

}
