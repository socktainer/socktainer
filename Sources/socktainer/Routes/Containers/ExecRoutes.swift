import ContainerAPIClient
import ContainerResource
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

// Helper to convert pipes to stdio array
struct Stdio {
    let stdin: FileHandle?
    let stdout: FileHandle?
    let stderr: FileHandle?

    var asArray: [FileHandle?] {
        [stdin, stdout, stderr]
    }
}

struct ExecRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/exec", use: ExecRoute.createExec(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/exec/{id}/json", use: ExecRoute.inspectExec(client: client))
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id}/start", use: ExecRoute.startExec(client: client))
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

            let detach = startRequest.Detach ?? false
            let tty = startRequest.Tty ?? config.tty
            let _ = startRequest.ConsoleSize

            // Detached mode
            if detach {
                let executable = config.cmd.first!
                let arguments = Array(config.cmd.dropFirst())
                var processConfig = container.configuration.initProcess
                processConfig.executable = executable
                processConfig.arguments = arguments
                processConfig.terminal = tty
                try ExecRoute.applyProcessOverrides(&processConfig, config: config)

                do {
                    let process = try await ContainerClient().createProcess(
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
                await ExecManager.shared.remove(id: execId)
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

                    // Setup pipes
                    let stdinPipe: Pipe? = config.attachStdin ? Pipe() : nil
                    let stdoutPipe: Pipe? = config.attachStdout ? Pipe() : nil
                    let stderrPipe: Pipe? = (config.attachStderr && !tty) ? Pipe() : nil

                    let stdio = Stdio(
                        stdin: stdinPipe?.fileHandleForReading,
                        stdout: stdoutPipe?.fileHandleForWriting,
                        stderr: stderrPipe?.fileHandleForWriting
                    )

                    let executable = config.cmd.first!
                    let arguments = Array(config.cmd.dropFirst())
                    var processConfig = container.configuration.initProcess
                    processConfig.executable = executable
                    processConfig.arguments = arguments
                    processConfig.terminal = tty
                    try ExecRoute.applyProcessOverrides(&processConfig, config: config)

                    let process = try await ContainerClient().createProcess(
                        containerId: container.id,
                        processId: UUID().uuidString.lowercased(),
                        configuration: processConfig,
                        stdio: stdio.asArray
                    )

                    do {
                        try await process.start()
                    } catch {
                        // Record an exit code so a failed start doesn't leave
                        // the exec stuck reporting Running forever.
                        await ExecManager.shared.setExitCode(id: execId, code: -1)
                        throw error
                    }

                    await withTaskGroup(of: Void.self) { group in
                        // stdout handler
                        if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                            group.addTask {
                                defer {
                                    try? stdoutHandle.close()
                                }

                                let state = DockerConnectionState()

                                while !state.shouldStop() {
                                    do {
                                        // A blocking pipe read returns empty Data only at EOF —
                                        // the process exited and its stdout writer was closed.
                                        // Break so the task group can finish and the response
                                        // stream is closed; sleeping/continuing here spins forever
                                        // and the Docker client hangs waiting for the stream to end.
                                        guard let data = try stdoutHandle.read(upToCount: 8192), !data.isEmpty else {
                                            break
                                        }

                                        let bufferSize = min(data.count + (tty ? 0 : 8), 65536)
                                        var buffer = sharedAllocator.buffer(capacity: bufferSize)
                                        buffer.writeDockerFrame(streamType: .stdout, data: data, ttyMode: tty)
                                        streamContinuation.yield(buffer)
                                    } catch {
                                        break
                                    }
                                }
                            }
                        }

                        // stderr handler
                        if let stderrHandle = stderrPipe?.fileHandleForReading {
                            group.addTask {
                                defer {
                                    try? stderrHandle.close()
                                }

                                let state = DockerConnectionState()

                                while !state.shouldStop() {
                                    do {
                                        // A blocking pipe read returns empty Data only at EOF —
                                        // the process exited and its stderr writer was closed.
                                        // Break so the task group can finish and the response
                                        // stream is closed; sleeping/continuing here spins forever
                                        // and the Docker client hangs waiting for the stream to end.
                                        guard let data = try stderrHandle.read(upToCount: 8192), !data.isEmpty else {
                                            break
                                        }

                                        let bufferSize = min(data.count + 8, 65536)
                                        var buffer = sharedAllocator.buffer(capacity: bufferSize)
                                        buffer.writeDockerFrame(streamType: .stderr, data: data, ttyMode: tty)
                                        streamContinuation.yield(buffer)
                                    } catch {
                                        break
                                    }
                                }
                            }
                        }

                        // stdin handler for HTTP mode
                        if let stdinWriter = stdinPipe?.fileHandleForWriting {
                            group.addTask {
                                defer {
                                    try? stdinWriter.close()
                                }

                                do {
                                    for try await var buf in req.body {
                                        if let data = buf.readData(length: buf.readableBytes) {
                                            try stdinWriter.write(contentsOf: data)
                                        }
                                    }
                                } catch {
                                }
                            }
                        }

                        // Process monitor
                        group.addTask {
                            defer {
                                // Close all write ends to signal EOF
                                try? stdoutPipe?.fileHandleForWriting.close()
                                try? stderrPipe?.fileHandleForWriting.close()
                                try? stdinPipe?.fileHandleForWriting.close()
                            }

                            do {
                                let exitCode = try await process.wait()
                                await ExecManager.shared.setExitCode(id: execId, code: exitCode)
                            } catch {
                                // process.wait() failed — record a synthetic exit
                                // code so the exec leaves the Running state.
                                await ExecManager.shared.setExitCode(id: execId, code: -1)
                            }
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

                // Setup pipes with detailed logging
                let stdinPipe: Pipe? = config.attachStdin ? Pipe() : nil
                let stdoutPipe: Pipe? = config.attachStdout ? Pipe() : nil
                let stderrPipe: Pipe? = (config.attachStderr && !tty) ? Pipe() : nil

                let stdio = Stdio(
                    stdin: stdinPipe?.fileHandleForReading,
                    stdout: stdoutPipe?.fileHandleForWriting,
                    stderr: stderrPipe?.fileHandleForWriting
                )

                // Connect TCP handler to stdin writer for bidirectional communication
                if let stdinWriter = stdinPipe?.fileHandleForWriting {
                    tcpHandler.setStdinWriter(stdinWriter)
                }

                let executable = config.cmd.first!
                let arguments = Array(config.cmd.dropFirst())

                var processConfig = container.configuration.initProcess
                processConfig.executable = executable
                processConfig.arguments = arguments
                processConfig.terminal = tty
                try ExecRoute.applyProcessOverrides(&processConfig, config: config)

                let process = try await ContainerClient().createProcess(
                    containerId: container.id,
                    processId: UUID().uuidString.lowercased(),
                    configuration: processConfig,
                    stdio: stdio.asArray
                )

                do {
                    try await process.start()
                } catch {
                    // Record an exit code so a failed start doesn't leave the
                    // exec stuck reporting Running forever.
                    await ExecManager.shared.setExitCode(id: execId, code: -1)
                    throw error
                }

                // Setup bidirectional communication for interactive sessions
                await withTaskGroup(of: Void.self) { group in
                    // stdout/stderr -> channel (container output to client)
                    if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                        group.addTask {
                            defer {
                                try? stdoutHandle.close()
                            }

                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stdoutHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { error in
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

                    if let stderrHandle = stderrPipe?.fileHandleForReading {
                        group.addTask {
                            defer {
                                try? stderrHandle.close()
                            }

                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stderrHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { error in
                                // Cleanup handled automatically
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
                        do {
                            let exitCode = try await process.wait()
                            await ExecManager.shared.setExitCode(id: execId, code: exitCode)
                        } catch {
                            // process.wait() failed — record a synthetic exit code
                            // so the exec leaves the Running state instead of
                            // hanging there forever.
                            await ExecManager.shared.setExitCode(id: execId, code: -1)
                        }

                        // Give a small delay for any final output to be processed
                        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

                        // Close all pipes to signal EOF to readers
                        try? stdoutPipe?.fileHandleForWriting.close()
                        try? stderrPipe?.fileHandleForWriting.close()
                        try? stdinPipe?.fileHandleForWriting.close()

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
}
