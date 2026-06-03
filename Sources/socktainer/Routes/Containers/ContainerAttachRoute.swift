import ContainerAPIClient
import ContainerResource
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

        // A non-stdin attach streams the container's log regardless of whether
        // stdout, stderr, or both (the default) were requested. Apple container
        // exposes a single primary log handle, so a stderr-only attach streams
        // that same source rather than short-circuiting to no output.
        let shouldStreamOutput = stdout || stderr || (!stdout && !stderr)

        // Create streaming response body using container logs when not using stdin
        let body = Response.Body { writer in
            Task.detached {
                defer {
                    _ = writer.write(.end)
                }

                // Flush the response head immediately. `docker run` opens the attach
                // connection and waits for the attach response before sending /start;
                // a Vapor streaming body otherwise withholds headers until the first
                // write, deadlocking attach-before-start. An empty buffer sends the head.
                _ = writer.write(.buffer(sharedAllocator.buffer(capacity: 0)))

                // Wait until the log file is available (container must be created first).
                var logHandle: FileHandle? = nil
                while logHandle == nil {
                    if let fhs = try? await ContainerClient().logs(id: container.id), !fhs.isEmpty {
                        logHandle = fhs[0]
                        // Close the boot-log handle we don't need.
                        if fhs.count > 1 { try? fhs[1].close() }
                        break
                    }
                    // Container may not be created yet; retry shortly.
                    try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                }

                guard let fileHandle = logHandle, shouldStreamOutput else { return }
                defer { try? fileHandle.close() }

                // Drain a chunk of log data, framing it as a Docker stdout/stderr stream.
                // Returns true if any bytes were written. Awaits each write so a
                // client disconnect (the write future fails once the channel is
                // closed) throws and ends the poll promptly instead of looping
                // until the container stops.
                @Sendable func drainAvailable() async throws -> Bool {
                    // When the client requested stderr only, label frames as stderr so
                    // demultiplexing clients route the bytes correctly; otherwise stdout.
                    // Apple exposes a single primary log handle, so the source is the same.
                    let frameStreamType: DockerStreamFrame.StreamType = (stderr && !stdout) ? .stderr : .stdout
                    var wrote = false
                    while let data = try? fileHandle.read(upToCount: 4096), !data.isEmpty {
                        wrote = true
                        let capacity = min(data.count + (isTTY ? 0 : 8), 65536)
                        var buf = sharedAllocator.buffer(capacity: capacity)
                        buf.writeDockerFrame(streamType: frameStreamType, data: data, ttyMode: isTTY)
                        try await writer.write(.buffer(buf)).get()
                    }
                    return wrote
                }

                // Stream log output by polling the log file for new writes. A
                // DispatchSource on the log fd is fragile: it can fire on a
                // closed/invalidated fd during teardown (container removed or
                // client disconnect) and crash the whole process with a
                // libdispatch trap (see socktainer/socktainer#205 for the same
                // bug in the logs route). Polling is robust. Drain, then poll
                // until the container is no longer running, then do a final drain.
                let containerClient = ContainerClient()
                do {
                    _ = try await drainAvailable()
                    while true {
                        let wrote = try await drainAvailable()
                        if !wrote {
                            let current = try? await containerClient.get(id: container.id)
                            if current == nil || current?.status != .running {
                                // Give the log a brief moment to flush the last bytes.
                                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                                _ = try await drainAvailable()
                                break
                            }
                            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
                        }
                    }
                } catch {
                    // Client disconnected (a write failed) — stop streaming.
                }
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
        container: ContainerSnapshot,
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
        // WARN: docker compose reaches this logic
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
        container: ContainerSnapshot,
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

        // Mirror ClientContainerService.start()'s exit-code contract: /wait returns
        // as soon as ContainerExitCodeStore is non-nil, so clear any stale code
        // before starting and record a synthetic one if bootstrap/start fails (so
        // /wait can't return a stale status or poll forever).
        await ContainerExitCodeStore.shared.remove(id: container.id)

        let process: ClientProcess
        do {
            process = try await ContainerClient().bootstrap(id: container.id, stdio: stdio)
        } catch {
            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
            throw Abort(.internalServerError, reason: "Failed to bootstrap container: \(error.localizedDescription)")
        }

        do {
            try await process.start()
        } catch {
            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
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
                        defer {
                            // Close pipes to break the reader loops
                            try? stdoutPipe?.fileHandleForWriting.close()
                            try? stderrPipe?.fileHandleForWriting.close()
                            try? stdinPipe.fileHandleForWriting.close()

                            // Close stream
                            streamContinuation.finish()
                        }

                        do {
                            // Record the real exit code so /containers/{id}/wait can return it.
                            let code = try await process.wait()
                            await ContainerExitCodeStore.shared.set(id: container.id, code: code)
                        } catch {
                            // process.wait() failed — record a synthetic exit code so
                            // /containers/{id}/wait can't block forever.
                            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
                        }
                    }

                    if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                        group.addTask {
                            defer {
                                try? stdoutHandle.close()
                            }

                            while true {
                                do {
                                    // A blocking pipe read returns empty Data only at EOF —
                                    // the attached process exited and closed its stdout writer.
                                    // Break so the stream finishes; sleeping/continuing here
                                    // spins forever and the attached client hangs.
                                    guard let data = try stdoutHandle.read(upToCount: 8192), !data.isEmpty else {
                                        break
                                    }

                                    let capacity = min(data.count + (isTTY ? 0 : 8), 65536)  // Cap buffer size
                                    var buffer = sharedAllocator.buffer(capacity: capacity)
                                    buffer.writeDockerFrame(streamType: .stdout, data: data, ttyMode: isTTY)
                                    streamContinuation.yield(buffer)
                                } catch {
                                    break
                                }
                            }
                        }
                    }

                    if let stderrHandle = stderrPipe?.fileHandleForReading {
                        group.addTask {
                            defer {
                                try? stderrHandle.close()
                            }

                            while true {
                                do {
                                    // A blocking pipe read returns empty Data only at EOF —
                                    // the attached process exited and closed its stderr writer.
                                    // Break so the stream finishes; sleeping/continuing here
                                    // spins forever and the attached client hangs.
                                    guard let data = try stderrHandle.read(upToCount: 8192), !data.isEmpty else {
                                        break
                                    }

                                    let capacity = min(data.count + 8, 65536)  // Cap buffer size
                                    var buffer = sharedAllocator.buffer(capacity: capacity)
                                    buffer.writeDockerFrame(streamType: .stderr, data: data, ttyMode: isTTY)
                                    streamContinuation.yield(buffer)
                                } catch {
                                    break
                                }
                            }
                        }
                    }

                    let stdinWriter = stdinPipe.fileHandleForWriting
                    group.addTask {
                        defer {
                            try? stdinWriter.close()
                        }

                        do {
                            for try await var buf in req.body {
                                if let data = buf.readData(length: buf.readableBytes) {
                                    try stdinWriter.write(contentsOf: data)
                                    try stdinWriter.synchronize()
                                }
                            }
                        } catch {
                        }
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
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stdoutHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { error in
                                continuation.resume()
                            }

                            dispatchIO.setLimit(lowWater: 1)
                            dispatchIO.setLimit(highWater: 8192)

                            let state = DockerConnectionState()

                            @Sendable func readNextChunk() {
                                dispatchIO.read(
                                    offset: off_t.max,
                                    length: 8192,
                                    queue: DispatchQueue.global(qos: .userInteractive)
                                ) { done, data, error in
                                    guard !done || error == 0 else {
                                        state.finish {
                                            dispatchIO.close()
                                        }
                                        return
                                    }
                                    guard let data = data else {
                                        state.finish {
                                            dispatchIO.close()
                                        }
                                        return
                                    }
                                    guard !data.isEmpty || !done else {
                                        state.finish {
                                            dispatchIO.close()
                                        }
                                        return
                                    }

                                    if !data.isEmpty {
                                        channel.eventLoop.execute {
                                            let capacity = min(data.count + (isTTY ? 0 : 8), 65536)
                                            var outputBuffer = channel.allocator.buffer(capacity: capacity)
                                            if isTTY {
                                                outputBuffer.writeBytes(data)
                                            } else {
                                                outputBuffer.writeDockerFrame(streamType: .stdout, data: Data(data), ttyMode: false)
                                            }
                                            _ = channel.writeAndFlush(outputBuffer)
                                        }
                                    }

                                    if done && !state.shouldStop() {
                                        DispatchQueue.global(qos: .userInteractive).async {
                                            readNextChunk()
                                        }
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
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stderrHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { error in
                                continuation.resume()
                            }

                            dispatchIO.setLimit(lowWater: 1)
                            dispatchIO.setLimit(highWater: 8192)

                            let state = DockerConnectionState()

                            @Sendable func readNextChunk() {
                                dispatchIO.read(
                                    offset: off_t.max,
                                    length: 8192,
                                    queue: DispatchQueue.global(qos: .userInteractive)
                                ) { done, data, error in
                                    guard !done || error == 0 else {
                                        state.finish {
                                            dispatchIO.close()
                                        }
                                        return
                                    }
                                    guard let data = data else {
                                        state.finish {
                                            dispatchIO.close()
                                        }
                                        return
                                    }
                                    guard !data.isEmpty || !done else {
                                        state.finish {
                                            dispatchIO.close()
                                        }
                                        return
                                    }

                                    if !data.isEmpty {
                                        channel.eventLoop.execute {
                                            let capacity = min(data.count + (isTTY ? 0 : 8), 65536)
                                            var outputBuffer = channel.allocator.buffer(capacity: capacity)
                                            if isTTY {
                                                outputBuffer.writeBytes(data)
                                            } else {
                                                outputBuffer.writeDockerFrame(streamType: .stderr, data: Data(data), ttyMode: false)
                                            }
                                            _ = channel.writeAndFlush(outputBuffer)
                                        }
                                    }

                                    if done && !state.shouldStop() {
                                        DispatchQueue.global(qos: .userInteractive).async {
                                            readNextChunk()
                                        }
                                    }
                                }
                            }

                            readNextChunk()
                        }

                        try? stderrHandle.close()
                    }
                }

                group.addTask {
                    let maxWaits = 6000  // 10 minutes max (6000 * 100ms)
                    for _ in 0..<maxWaits {
                        guard channel.isActive else { break }
                        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                    }
                }

                group.addTask {
                    do {
                        // Record the real exit code so /containers/{id}/wait can return it.
                        let code = try await process.wait()
                        await ContainerExitCodeStore.shared.set(id: container.id, code: code)
                    } catch {
                        // process.wait() failed — record a synthetic exit code so
                        // /containers/{id}/wait can't block forever.
                        await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
                    }

                    // Give a small delay for any final output to be processed
                    try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

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
