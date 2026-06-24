import ContainerAPIClient
import ContainerResource
import ContainerizationOS
import Foundation
import NIOCore
import Vapor

// Singleton ExecManager to track exec configs
actor ExecManager {
    static let shared = ExecManager()

    struct ExecConfig {
        let containerId: String
        let cmd: [String]
        let attachStdin: Bool
        let attachStdout: Bool
        let attachStderr: Bool
        let tty: Bool
        let detach: Bool
        let env: [String]
        let user: String?
        let workingDir: String?
    }

    private var storage: [String: ExecConfig] = [:]
    private var exitCodes: [String: Int32] = [:]
    private var startedIds: Set<String> = []

    func create(config: ExecConfig) -> String {
        let id = UUID().uuidString
        storage[id] = config
        return id
    }

    func get(id: String) -> ExecConfig? {
        storage[id]
    }

    func remove(id: String) {
        storage.removeValue(forKey: id)
        exitCodes.removeValue(forKey: id)
        startedIds.remove(id)
    }

    // Marks an exec as started. Returns false if it doesn't exist or was already
    // started — Docker rejects starting an exec instance more than once.
    func markStarted(id: String) -> Bool {
        guard storage[id] != nil, !startedIds.contains(id) else { return false }
        startedIds.insert(id)
        return true
    }

    // An exec is "running" only once it has been started and has not yet
    // recorded an exit code — distinct from created-but-not-started.
    func isRunning(id: String) -> Bool {
        startedIds.contains(id) && exitCodes[id] == nil
    }

    // The Docker client calls `GET /exec/{id}/json` after the start stream
    // closes to read the exit code, so the exec entry must outlive the stream.
    func setExitCode(id: String, code: Int32) {
        exitCodes[id] = code
    }

    func exitCode(id: String) -> Int32? {
        exitCodes[id]
    }
}

// Request & Response DTOs
struct CreateExecRequest: Content {
    let Cmd: [String]
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let Tty: Bool?
    let Env: [String]?
    let User: String?
    let WorkingDir: String?
}

struct CreateExecResponse: Content {
    let Id: String
}

struct ExecRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/exec", use: ExecRoute.createExec(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/exec/{id}/json", use: ExecRoute.inspectExec(client: client))
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id}/start", use: ExecRoute.startExec(client: client))
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id}/resize", use: ExecRoute.resizeExec)
    }

    static func inspectExec(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let execId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing exec ID")
            }

            guard let config = await ExecManager.shared.get(id: execId) else {
                throw Abort(.notFound, reason: "Exec process not found")
            }

            struct ExecInspectResponse: Content {
                let ID: String
                let Running: Bool
                let ExitCode: Int?
                let ProcessConfig: ProcessConfigInfo
                let OpenStdin: Bool
                let OpenStderr: Bool
                let OpenStdout: Bool
                let CanRemove: Bool
                let ContainerID: String
                let DetachKeys: String
                let Pid: Int?

                struct ProcessConfigInfo: Content {
                    let privileged: Bool
                    let user: String
                    let tty: Bool
                    let entrypoint: String
                    let arguments: [String]
                    let workingDir: String
                    let env: [String]
                }
            }

            // Running is true only once started and before an exit code is
            // recorded — a created-but-not-yet-started exec is not running.
            let recordedExitCode = await ExecManager.shared.exitCode(id: execId)
            let response = ExecInspectResponse(
                ID: execId,
                Running: await ExecManager.shared.isRunning(id: execId),
                ExitCode: recordedExitCode.map { Int($0) },
                ProcessConfig: ExecInspectResponse.ProcessConfigInfo(
                    privileged: false,
                    user: config.user ?? "",
                    tty: config.tty,
                    entrypoint: config.cmd.first ?? "",
                    arguments: Array(config.cmd.dropFirst()),
                    workingDir: config.workingDir ?? "",
                    env: config.env
                ),
                OpenStdin: config.attachStdin,
                OpenStderr: config.attachStderr,
                OpenStdout: config.attachStdout,
                CanRemove: true,
                ContainerID: config.containerId,
                DetachKeys: "",
                Pid: nil
            )

            return Response(status: .ok, body: .init(data: try JSONEncoder().encode(response)))
        }
    }

    static func createExec(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: containerId) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            do {
                try client.enforceContainerRunning(container: container)
            } catch {
                throw Abort(.conflict, reason: "Container is not running")
            }

            let body = try req.content.decode(CreateExecRequest.self)

            // there is an error if we provides attachStderr with terminal true
            var attachStderr = body.AttachStderr ?? true
            if body.Tty ?? false {
                attachStderr = false
            }

            let config = ExecManager.ExecConfig(
                containerId: containerId,
                cmd: body.Cmd,
                attachStdin: body.AttachStdin ?? false,
                attachStdout: body.AttachStdout ?? true,
                attachStderr: attachStderr,
                tty: body.Tty ?? false,
                detach: false,
                env: body.Env ?? [],
                user: body.User,
                workingDir: body.WorkingDir
            )

            let id = await ExecManager.shared.create(config: config)
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                var attrs = LabelNormalization.restore(container.configuration.labels)
                attrs["execID"] = id
                // Docker formats the action as "exec_create: <command>" (action + ": " + cmd).
                let event = DockerEvent.simpleEvent(
                    id: DockerContainerID.hexId(for: container),
                    type: "container",
                    status: "exec_create: \(config.cmd.joined(separator: " "))",
                    image: container.configuration.image.reference,
                    name: container.id,
                    labels: attrs
                )
                await broadcaster.broadcast(event)
            }
            return Response(status: .created, body: .init(data: try JSONEncoder().encode(CreateExecResponse(Id: id))))
        }
    }

    // Applies the exec request's Env, User and WorkingDir on top of the
    // container's init process configuration, mirroring how container create
    // handles the same fields. Without this the Docker API fields are ignored
    // and execs always run with the container's defaults.
    static func applyProcessOverrides(_ processConfig: inout ProcessConfiguration, config: ExecManager.ExecConfig) throws {
        if !config.env.isEmpty {
            processConfig.environment = try Parser.allEnv(imageEnvs: processConfig.environment, envFiles: [], envs: config.env)
        }
        if let workingDir = config.workingDir, !workingDir.isEmpty {
            processConfig.workingDirectory = workingDir
        }
        if let user = config.user, !user.isEmpty {
            processConfig.user = .raw(userString: user)
        }
    }

    static func startExec(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let execId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing exec ID")
            }

            guard let config = await ExecManager.shared.get(id: execId) else {
                throw Abort(.notFound, reason: "Exec process not found")
            }

            guard let container = try await client.getContainer(id: config.containerId) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            try client.enforceContainerRunning(container: container)

            // Apply the request's Env/User/WorkingDir before marking the exec
            // started: applying them can throw, and doing so after markStarted
            // would leave the exec reported as running forever.
            let baseProcessConfig: ProcessConfiguration = try {
                var processConfig = container.configuration.initProcess
                try ExecRoute.applyProcessOverrides(&processConfig, config: config)
                return processConfig
            }()

            // Reject starting an exec instance more than once (Docker semantics).
            guard await ExecManager.shared.markStarted(id: execId) else {
                throw Abort(.conflict, reason: "Exec instance \(execId) has already been started")
            }

            struct StartExecRequest: Content {
                let Detach: Bool?
                let Tty: Bool?
                let ConsoleSize: [Int]?
            }

            let startRequest = try req.content.decode(StartExecRequest.self)

            // Capture values for exec_start / exec_die events — must happen before any
            // streaming closure so they're available deep inside task groups without
            // capturing `req`. exec_start fires only once the process actually starts
            // (after process.start() succeeds), so a failed exec emits no started event.
            let execBroadcaster = req.application.storage[EventBroadcasterKey.self]
            let execEventHexId = DockerContainerID.hexId(for: container)
            let execEventImage = container.configuration.image.reference
            let execEventName = container.id
            let execEventLabels = LabelNormalization.restore(container.configuration.labels)
            // Docker formats the action as "exec_start: <command>" (action + ": " + cmd).
            let execStartAction = "exec_start: \(config.cmd.joined(separator: " "))"

            @Sendable func broadcastExecEvent(_ status: String, exitCode: Int32? = nil) async {
                guard let broadcaster = execBroadcaster else { return }
                var attrs = execEventLabels
                attrs["execID"] = execId
                if let exitCode { attrs["exitCode"] = String(exitCode) }
                let event = DockerEvent.simpleEvent(
                    id: execEventHexId, type: "container", status: status,
                    image: execEventImage, name: execEventName, labels: attrs)
                await broadcaster.broadcast(event)
            }

            let detach = startRequest.Detach ?? false
            let tty = startRequest.Tty ?? config.tty
            // Docker sends ConsoleSize as [height, width] for interactive (-it) exec.
            // Apply it as the initial PTY winsize right after start so `stty size` and TUIs
            // (vim/htop/less) work, rather than relying solely on the async /exec/{id}/resize
            // call, which can race the process registration and be dropped.
            let initialTerminalSize = ExecRoute.initialTerminalSize(tty: tty, consoleSize: startRequest.ConsoleSize)

            // Detached mode
            if detach {
                let executable = config.cmd.first!
                let arguments = Array(config.cmd.dropFirst())
                var processConfig = baseProcessConfig
                processConfig.executable = executable
                processConfig.arguments = arguments
                processConfig.terminal = tty

                let process: ClientProcess
                do {
                    process = try await ContainerClient().createProcess(
                        containerId: container.id,
                        processId: UUID().uuidString.lowercased(),
                        configuration: processConfig,
                        stdio: [nil, nil, nil]
                    )
                    try await process.start()
                } catch {
                    // The exec was marked started; if creating/starting the
                    // process fails we must record an exit code, otherwise the
                    // exec is stuck reporting Running forever.
                    await ExecManager.shared.setExitCode(id: execId, code: -1)
                    throw error
                }
                await broadcastExecEvent(execStartAction)
                // Observe the detached process so docker exec -d still reports completion
                // (exit code + exec_die), mirroring the container.die observer. Keep the
                // ExecManager entry afterwards — the recorded exit code must remain readable
                // via GET /exec/{id}/json (matching the attached HTTP/TCP paths).
                Task.detached {
                    let code: Int32
                    do { code = try await process.wait() } catch { code = -1 }
                    await ExecManager.shared.setExitCode(id: execId, code: code)
                    await broadcastExecEvent("exec_die", exitCode: code)
                }
                return Response(status: .ok)
            }

            // Check if client requested connection upgrade and attachStdin is true
            let connectionHeader = req.headers.first(name: "Connection")?.lowercased()
            let upgradeHeader = req.headers.first(name: "Upgrade")?.lowercased()
            let shouldUpgrade = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp" && config.attachStdin

            guard shouldUpgrade else {
                // Fallback to HTTP streaming mode
                return ConnectionHijackingMiddleware.createDockerStreamingResponse(
                    request: req,
                    ttyEnabled: tty
                ) { streamContinuation in

                    guard
                        let pipes = StdioPipes.make(
                            stdin: config.attachStdin,
                            stdout: config.attachStdout,
                            stderr: config.attachStderr && !tty
                        )
                    else {
                        await ExecManager.shared.setExitCode(id: execId, code: -1)
                        throw Abort(.internalServerError, reason: "Failed to create I/O pipes")
                    }

                    let executable = config.cmd.first!
                    let arguments = Array(config.cmd.dropFirst())
                    var processConfig = baseProcessConfig
                    processConfig.executable = executable
                    processConfig.arguments = arguments
                    processConfig.terminal = tty

                    let process: ClientProcess
                    do {
                        process = try await ContainerClient().createProcess(
                            containerId: container.id,
                            processId: UUID().uuidString.lowercased(),
                            configuration: processConfig,
                            stdio: pipes.stdioArray
                        )
                    } catch {
                        pipes.closeAll()
                        await ExecManager.shared.setExitCode(id: execId, code: -1)
                        throw error
                    }

                    do {
                        try await process.start()
                    } catch {
                        pipes.closeAfterHandoff()
                        await ExecManager.shared.setExitCode(id: execId, code: -1)
                        throw error
                    }
                    await broadcastExecEvent(execStartAction)

                    await ProcessRegistry.shared.set(id: execId, process: process)
                    if let initialTerminalSize { try? await process.resize(initialTerminalSize) }

                    await withTaskGroup(of: Void.self) { group in
                        // stdout handler
                        if let stdoutRead = pipes.stdout?.read {
                            group.addTask {
                                defer { try? stdoutRead.close() }
                                while true {
                                    do {
                                        // A blocking pipe read returns empty Data only at EOF —
                                        // the process exited and its stdout writer was closed.
                                        guard let data = try stdoutRead.read(upToCount: 8192), !data.isEmpty else {
                                            break
                                        }
                                        let bufferSize = min(data.count + (tty ? 0 : 8), 65536)
                                        var buffer = sharedAllocator.buffer(capacity: bufferSize)
                                        buffer.writeDockerFrame(streamType: .stdout, data: data, ttyMode: tty)
                                        streamContinuation.yield(buffer)
                                    } catch { break }
                                }
                            }
                        }

                        // stderr handler
                        if let stderrRead = pipes.stderr?.read {
                            group.addTask {
                                defer { try? stderrRead.close() }
                                while true {
                                    do {
                                        // A blocking pipe read returns empty Data only at EOF —
                                        // the process exited and its stderr writer was closed.
                                        guard let data = try stderrRead.read(upToCount: 8192), !data.isEmpty else {
                                            break
                                        }
                                        let bufferSize = min(data.count + 8, 65536)
                                        var buffer = sharedAllocator.buffer(capacity: bufferSize)
                                        buffer.writeDockerFrame(streamType: .stderr, data: data, ttyMode: tty)
                                        streamContinuation.yield(buffer)
                                    } catch { break }
                                }
                            }
                        }

                        // stdin handler for HTTP mode
                        if let stdinWrite = pipes.stdin?.write {
                            group.addTask {
                                defer { try? stdinWrite.close() }
                                do {
                                    for try await var buf in req.body {
                                        if let data = buf.readData(length: buf.readableBytes) {
                                            try stdinWrite.write(contentsOf: data)
                                        }
                                    }
                                } catch {}
                            }
                        }

                        // Process monitor
                        group.addTask {
                            let code: Int32
                            do {
                                code = try await process.wait()
                            } catch {
                                // process.wait() failed — record a synthetic exit
                                // code so the exec leaves the Running state.
                                code = -1
                            }
                            await ExecManager.shared.setExitCode(id: execId, code: code)
                            await ProcessRegistry.shared.remove(id: execId)
                            await broadcastExecEvent("exec_die", exitCode: code)
                        }

                        for await _ in group {}
                    }

                    // Keep the exec entry so the client's follow-up
                    // `GET /exec/{id}/json` can read the recorded exit code.
                    streamContinuation.finish()
                }
            }
            // Use Docker TCP upgrader for true connection hijacking

            return Response.dockerTCPUpgrade(
                execId: execId,
                ttyEnabled: tty
            ) { channel, tcpHandler in

                guard
                    let pipes = StdioPipes.make(
                        stdin: config.attachStdin,
                        stdout: config.attachStdout,
                        stderr: config.attachStderr && !tty
                    )
                else {
                    await ExecManager.shared.setExitCode(id: execId, code: -1)
                    throw Abort(.internalServerError, reason: "Failed to create I/O pipes")
                }

                let executable = config.cmd.first!
                let arguments = Array(config.cmd.dropFirst())

                var processConfig = baseProcessConfig
                processConfig.executable = executable
                processConfig.arguments = arguments
                processConfig.terminal = tty

                let process: ClientProcess
                do {
                    process = try await ContainerClient().createProcess(
                        containerId: container.id,
                        processId: UUID().uuidString.lowercased(),
                        configuration: processConfig,
                        stdio: pipes.stdioArray
                    )
                } catch {
                    pipes.closeAll()
                    await ExecManager.shared.setExitCode(id: execId, code: -1)
                    throw error
                }
                do {
                    try await process.start()
                } catch {
                    pipes.closeAfterHandoff()
                    await ExecManager.shared.setExitCode(id: execId, code: -1)
                    throw error
                }
                await broadcastExecEvent(execStartAction)
                // Wire stdin only after start() succeeds so closeAfterHandoff()
                // remains the sole owner on any failure path before this point.
                if let stdinWrite = pipes.stdin?.write {
                    tcpHandler.setStdinWriter(stdinWrite)
                }

                await ProcessRegistry.shared.set(id: execId, process: process)
                if let initialTerminalSize { try? await process.resize(initialTerminalSize) }

                // Setup bidirectional communication for interactive sessions
                await withTaskGroup(of: Void.self) { group in
                    // stdout/stderr -> channel (container output to client)
                    if let stdoutHandle = pipes.stdout?.read {
                        group.addTask {
                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stdoutHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { _ in
                                // DispatchIO relinquishes the fd in its cleanup handler.
                                // Close here to avoid closing a potentially recycled fd.
                                try? stdoutHandle.close()
                            }

                            defer {
                                dispatchIO.close()
                            }

                            // Set up for streaming
                            dispatchIO.setLimit(lowWater: 1)
                            dispatchIO.setLimit(highWater: 4096)

                            let state = DockerConnectionState()

                            // Use a single read operation that processes all available data
                            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                                var hasCompleted = false
                                let completionLock = NSLock()

                                func safeComplete() {
                                    completionLock.lock()
                                    defer { completionLock.unlock() }
                                    guard !hasCompleted else { return }
                                    hasCompleted = true
                                    continuation.resume()
                                }

                                // Start a continuous read operation
                                dispatchIO.read(
                                    offset: 0,
                                    length: Int.max,  // Read all available data
                                    queue: DispatchQueue.global(qos: .userInteractive)
                                ) { done, data, error in

                                    completionLock.lock()
                                    let shouldProcess = !hasCompleted && channel.isActive
                                    completionLock.unlock()

                                    if shouldProcess, let data = data, !data.isEmpty {
                                        channel.eventLoop.execute {
                                            let bufferSize = min(data.count + (tty ? 0 : 8), 65536)
                                            var outputBuffer = channel.allocator.buffer(capacity: bufferSize)
                                            if tty {
                                                outputBuffer.writeBytes(data)
                                            } else {
                                                outputBuffer.writeDockerFrame(streamType: .stdout, data: Data(data), ttyMode: false)
                                            }
                                            _ = channel.writeAndFlush(outputBuffer)
                                        }
                                    }

                                    if done || error != 0 || !channel.isActive || state.shouldStop() {
                                        safeComplete()
                                    }
                                }
                            }
                        }
                    }

                    if let stderrHandle = pipes.stderr?.read {
                        group.addTask {
                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stderrHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { _ in
                                try? stderrHandle.close()
                            }

                            defer {
                                dispatchIO.close()
                            }

                            // Set up for streaming
                            dispatchIO.setLimit(lowWater: 1)
                            dispatchIO.setLimit(highWater: 1024)

                            let state = DockerConnectionState()

                            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                                var hasCompleted = false
                                let completionLock = NSLock()

                                func safeComplete() {
                                    completionLock.lock()
                                    defer { completionLock.unlock() }
                                    guard !hasCompleted else { return }
                                    hasCompleted = true
                                    continuation.resume()
                                }

                                // Start a continuous read operation
                                dispatchIO.read(
                                    offset: 0,
                                    length: Int.max,  // Read all available data
                                    queue: DispatchQueue.global(qos: .userInteractive)
                                ) { done, data, error in

                                    completionLock.lock()
                                    let shouldProcess = !hasCompleted && channel.isActive
                                    completionLock.unlock()

                                    if shouldProcess, let data = data, !data.isEmpty {
                                        channel.eventLoop.execute {
                                            let bufferSize = min(data.count + 8, 65536)
                                            var outputBuffer = channel.allocator.buffer(capacity: bufferSize)
                                            outputBuffer.writeDockerFrame(streamType: .stderr, data: Data(data), ttyMode: tty)
                                            _ = channel.writeAndFlush(outputBuffer)
                                        }
                                    }

                                    if done || error != 0 || !channel.isActive || state.shouldStop() {
                                        safeComplete()
                                    }
                                }
                            }
                        }
                    }

                    // Connection monitor to handle client disconnection
                    group.addTask {
                        // Monitor channel for closure - simplified approach
                        while channel.isActive {
                            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                        }

                        // Connection was closed - the process monitor will handle cleanup
                    }

                    // Process monitor with proper cleanup
                    group.addTask {
                        let code: Int32
                        do {
                            code = try await process.wait()
                        } catch {
                            // process.wait() failed — record a synthetic exit code
                            // so the exec leaves the Running state instead of
                            // hanging there forever.
                            code = -1
                        }
                        await ExecManager.shared.setExitCode(id: execId, code: code)
                        await ProcessRegistry.shared.remove(id: execId)
                        await broadcastExecEvent("exec_die", exitCode: code)

                        // Give a small delay for any final output to be processed
                        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

                        // DockerTCPHandler owns stdinPipe?.write after setStdinWriter(); it closes
                        // it via writeQueue on channelInactive / inputClosed. Closing it here too
                        // would be a double-close that can kill a reused fd.
                        // stdout/stderr write ends are Apple-owned — also do not close them.

                        // Close the channel gracefully
                        _ = channel.eventLoop.submit {
                            channel.close(promise: nil)
                        }
                    }

                    for await _ in group {}
                }

                // Keep the exec entry so the client's follow-up
                // `GET /exec/{id}/json` can read the recorded exit code.
            }
        }
    }

    /// Maps Docker's exec-start `ConsoleSize` to an initial terminal size.
    ///
    /// Docker encodes `ConsoleSize` as `[height, width]` and only sends it for
    /// interactive (`-it`) exec. Returns `nil` when there is no TTY or the value
    /// is absent/malformed, so callers skip the initial resize.
    static func initialTerminalSize(tty: Bool, consoleSize: [Int]?) -> ContainerizationOS.Terminal.Size? {
        guard tty, let cs = consoleSize, cs.count == 2, cs[0] > 0, cs[1] > 0 else { return nil }
        return ContainerizationOS.Terminal.Size(
            width: UInt16(min(cs[1], Int(UInt16.max))),
            height: UInt16(min(cs[0], Int(UInt16.max)))
        )
    }

    static let resizeExec: @Sendable (Request) async throws -> Response = { req in
        guard let execId = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing exec ID")
        }

        guard let h = try? req.query.get(Int.self, at: "h"), h > 0 else {
            throw Abort(.badRequest, reason: "Missing or invalid height parameter")
        }

        guard let w = try? req.query.get(Int.self, at: "w"), w > 0 else {
            throw Abort(.badRequest, reason: "Missing or invalid width parameter")
        }

        // 404 if exec instance never existed; 200 (no-op) if it ran and already exited.
        guard await ExecManager.shared.get(id: execId) != nil else {
            throw Abort(.notFound, reason: "No such exec instance: \(execId)")
        }

        if let process = await ProcessRegistry.shared.get(id: execId) {
            let size = Terminal.Size(width: UInt16(min(w, Int(UInt16.max))), height: UInt16(min(h, Int(UInt16.max))))
            try? await process.resize(size)
        }

        return Response(status: .ok)
    }
}
