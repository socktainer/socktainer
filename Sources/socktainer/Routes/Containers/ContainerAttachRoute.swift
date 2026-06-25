import ContainerAPIClient
import ContainerResource
import ContainerizationError
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
    /// Grace period between closing pipe write ends and unblocking /wait.
    /// Lets pipe readers flush buffered output before Docker CLI closes the connection.
    static let outputFlushGraceNs: UInt64 = 200_000_000  // 200ms

    /// Builds the container event emitted when `docker run --rm` triggers Apple Container's
    /// auto-removal: no DELETE arrives, so ContainerDeleteRoute never fires and this path
    /// substitutes for it. The action MUST be "destroy" — the same action ContainerDeleteRoute
    /// emits — because `--rm` is the same removal operation. Shared by the HTTP and WS attach
    /// routes so both stay consistent.
    static func makeAutoRemoveEvent(id: String, image: String, name: String, labels: [String: String]) -> DockerEvent {
        DockerEvent.simpleEvent(id: id, type: "container", status: "destroy", image: image, name: name, labels: labels)
    }

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

        // For stopped containers (the `docker run` flow), bootstrap with pipes regardless
        // of whether stdin is requested. The log-file polling path has a race condition
        // for fast-exiting containers (#220): the container can produce output and exit
        // before the polling loop finds the log file, silently dropping all output.
        // Pipe-based bootstrapping captures output directly and eliminates the race.
        if container.status == .stopped {
            guard stdin else {
                // Output-only attach (docker run / docker run -a STDOUT -a STDERR).
                // Docker CLI sends Connection: Upgrade even without -i, so we accept the
                // upgrade but return a Vapor streaming body — the same approach the original
                // log-file path used. The key improvement is pipe-based bootstrapping which
                // eliminates the race condition for fast-exiting containers (#220).
                return try await attachStoppedOutputOnly(
                    req: req,
                    hexId: id,
                    container: container,
                    query: query,
                    isTTY: isTTY,
                    isUpgrade: isUpgrade,
                    hasConnectionUpgrade: hasConnectionUpgrade
                )
            }
            // stdin=true (docker run -it): full bidirectional pipe approach via TCP upgrade.
            // Note: Docker CLI sends Connection: Upgrade even for non-stdin docker run, so
            // we cannot rely on upgrade headers to distinguish interactive vs output-only.
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
                // A snapshot attach (stream=0) drains once and ends instead of
                // following.
                let containerClient = ContainerClient()
                do {
                    _ = try await drainAvailable()
                    while stream {
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

    // Output-only attach for stopped containers (docker run without -i, issue #220).
    // Uses pipes instead of log-file polling to eliminate the race for fast-exiting containers.
    private static func attachStoppedOutputOnly(
        req: Request,
        hexId: String,
        container: ContainerSnapshot,
        query: ContainerAttachQuery,
        isTTY: Bool,
        isUpgrade: Bool,
        hasConnectionUpgrade: Bool
    ) async throws -> Response {
        let attachStdout = query.stdout ?? true
        let stderrOnly = (query.stderr ?? false) && !(query.stdout ?? false)

        // Always create a stdin pipe even though no data will flow through it.
        // Apple Container requires all three stdio handles to be non-nil to use
        // pipe mode; passing nil for stdin causes it to fall back to log-file mode
        // which has the race condition we are trying to fix.
        guard
            let pipes = StdioPipes.make(
                stdin: true,
                stdout: attachStdout,
                stderr: !isTTY && (query.stderr ?? false)
            )
        else {
            throw Abort(.internalServerError, reason: "Failed to create stdio pipes")
        }

        // No data will be written to stdin for non-interactive containers — close
        // our write end immediately so the container's stdin sees EOF.
        try? pipes.stdin?.write.close()

        await ContainerExitCodeStore.shared.remove(id: container.id)

        let process: ClientProcess
        do {
            process = try await ContainerClient().bootstrap(id: container.id, stdio: pipes.stdioArray)
        } catch {
            pipes.closeAll()
            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
            throw Abort(.internalServerError, reason: "Failed to bootstrap container: \(error.localizedDescription)")
        }

        do {
            try await process.start()
        } catch {
            if !isBenignStartRace(error) {
                pipes.closeAfterHandoff()
                await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
                throw Abort(.internalServerError, reason: "Failed to start container: \(error.localizedDescription)")
            }
        }

        await ProcessRegistry.shared.set(id: container.id, process: process)

        let contentType =
            isTTY
            ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        if isUpgrade && hasConnectionUpgrade {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
        }
        let status: HTTPResponseStatus = (isUpgrade && hasConnectionUpgrade) ? .switchingProtocols : .ok

        let body = Response.Body { writer in
            Task.detached {
                defer { _ = writer.write(.end) }
                _ = writer.write(.buffer(sharedAllocator.buffer(capacity: 0)))

                await withTaskGroup(of: Void.self) { group in
                    // Process monitor — stdout/stderr write ends and stdin read are Apple-owned.
                    group.addTask {
                        // Retry the wait XPC round-trip rather than collapsing a transient
                        // throw into a fake exit code of 0 (see ContainerExitCodeStore.resolveExitCode).
                        let code = await ContainerExitCodeStore.resolveExitCode { try await process.wait() }
                        await ProcessRegistry.shared.remove(id: container.id)
                        try? await Task.sleep(nanoseconds: Self.outputFlushGraceNs)
                        await ContainerExitCodeStore.shared.set(id: container.id, code: code)
                        await ContainerExitCodeStore.shared.set(id: hexId, code: code)

                        // docker run --rm: Apple Container auto-removes the container so DELETE
                        // never arrives and ContainerDeleteRoute never fires. consumeAutoRemove
                        // gates on the --rm flag (set at create) and dedups against the detached
                        // die observer, so exactly one "destroy" fires — same action moby uses.
                        if await ContainerInfoCache.shared.consumeAutoRemove(id: hexId) {
                            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                                let cached = await ContainerInfoCache.shared.get(id: hexId)
                                await broadcaster.broadcast(
                                    Self.makeAutoRemoveEvent(
                                        id: hexId,
                                        image: cached?.image ?? container.configuration.image.reference,
                                        name: cached?.nativeId ?? container.id,
                                        labels: cached?.labels
                                            ?? LabelNormalization.restore(container.configuration.labels)
                                    ))
                                await ContainerInfoCache.shared.remove(id: hexId)
                            }
                        }
                    }

                    // Stdout reader
                    if let stdoutHandle = pipes.stdout?.read {
                        let frameType: DockerStreamFrame.StreamType = stderrOnly ? .stderr : .stdout
                        group.addTask {
                            defer { try? stdoutHandle.close() }
                            while let data = try? stdoutHandle.read(upToCount: 8192), !data.isEmpty {
                                var buf = sharedAllocator.buffer(capacity: data.count + (isTTY ? 0 : 8))
                                buf.writeDockerFrame(streamType: frameType, data: data, ttyMode: isTTY)
                                _ = try? await writer.write(.buffer(buf)).get()
                            }
                        }
                    }

                    // Stderr reader (separate stream when both stdout and stderr requested)
                    if let stderrHandle = pipes.stderr?.read {
                        group.addTask {
                            defer { try? stderrHandle.close() }
                            while let data = try? stderrHandle.read(upToCount: 8192), !data.isEmpty {
                                var buf = sharedAllocator.buffer(capacity: data.count + 8)
                                buf.writeDockerFrame(streamType: .stderr, data: data, ttyMode: false)
                                _ = try? await writer.write(.buffer(buf)).get()
                            }
                        }
                    }

                    for await _ in group {}
                }
            }
        }

        return Response(status: status, headers: headers, body: body)
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
        guard
            let pipes = StdioPipes.make(
                stdin: true,
                stdout: attachStdout,
                stderr: attachStderr && !isTTY
            )
        else {
            throw Abort(.internalServerError, reason: "Failed to create stdio pipes")
        }

        // Mirror ClientContainerService.start()'s exit-code contract: /wait returns
        // as soon as ContainerExitCodeStore is non-nil, so clear any stale code
        // before starting and record a synthetic one if bootstrap/start fails (so
        // /wait can't return a stale status or poll forever).
        await ContainerExitCodeStore.shared.remove(id: container.id)

        let process: ClientProcess
        do {
            process = try await ContainerClient().bootstrap(id: container.id, stdio: pipes.stdioArray)
        } catch {
            pipes.closeAll()
            if isBenignStartRace(error) {
                throw Abort(.conflict, reason: "Container is already starting")
            }
            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
            throw Abort(.internalServerError, reason: "Failed to bootstrap container: \(error.localizedDescription)")
        }

        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            if isBenignStartRace(error) {
                throw Abort(.conflict, reason: "Container is already starting")
            }
            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
            throw Abort(.internalServerError, reason: "Failed to start main process: \(error.localizedDescription)")
        }

        await ProcessRegistry.shared.set(id: container.id, process: process)

        guard shouldUpgrade else {

            return ConnectionHijackingMiddleware.createDockerStreamingResponse(
                request: req,
                ttyEnabled: isTTY
            ) { streamContinuation in

                await withTaskGroup(of: Void.self) { group in
                    // Process monitor - when process exits, close pipes and finish stream
                    group.addTask {
                        defer {
                            // stdout/stderr write ends are Apple-owned — do not close them.
                            // stdin write end is owned by the stdin-writer task below; closing
                            // it here too would be a double-close on the same fd.
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
                        await ProcessRegistry.shared.remove(id: container.id)
                    }

                    if let stdoutHandle = pipes.stdout?.read {
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

                    if let stderrHandle = pipes.stderr?.read {
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

                    let stdinWriter = pipes.stdin!.write
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

            tcpHandler.setStdinWriter(pipes.stdin!.write)

            await withTaskGroup(of: Void.self) { group in
                if let stdoutHandle = pipes.stdout?.read {
                    group.addTask {
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stdoutHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { _ in
                                // Close in the cleanup handler — DispatchIO relinquishes
                                // the fd here, so it's safe to close without risk of
                                // closing a recycled descriptor.
                                try? stdoutHandle.close()
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
                    }
                }

                if let stderrHandle = pipes.stderr?.read {
                    group.addTask {
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stderrHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { _ in
                                try? stderrHandle.close()
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
                    await ProcessRegistry.shared.remove(id: container.id)

                    // Give a small delay for any final output to be processed
                    try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

                    // DockerTCPHandler owns pipes.stdin!.write after setStdinWriter(); it closes
                    // it via writeQueue on channelInactive / inputClosed. Closing it here too
                    // would be a double-close that can kill a reused fd.
                    // stdout/stderr write ends are Apple-owned — also do not close them.

                    // Close the channel gracefully only if still open.
                    // Calling close() on an already-closed channel causes
                    // EBADF which triggers a NIO precondition failure.
                    _ = channel.eventLoop.submit {
                        guard channel.isActive else { return }
                        channel.close(promise: nil)
                    }
                }

                for await _ in group {}
            }
        }
    }

}
