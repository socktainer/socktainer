import ContainerClient
import Foundation
import NIOCore
import Vapor

// Minimal Terminal wrapper for TTY support
struct Terminal {
    let handle: FileHandle

    static var current: Terminal {
        Terminal(handle: FileHandle.standardOutput)
    }

    func setRaw() throws {
        // Configure terminal to raw mode if needed
    }

    func reset() throws {
        // Reset terminal to normal mode
    }
}

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
    }

    private var storage: [String: ExecConfig] = [:]

    func create(config: ExecConfig) -> String {
        let id = UUID().uuidString
        storage[id] = config
        return id
    }

    func get(id: String) -> ExecConfig? {
        storage[id]
    }

    func remove(id: String) {
        // storage.removeValue(forKey: id)
    }
}

// Request & Response DTOs
struct CreateExecRequest: Content {
    let Cmd: [String]
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let Tty: Bool?
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
        routes.post(":version", "containers", ":id", "exec", use: ExecRoute.createExec(client: client))
        routes.post("containers", ":id", "exec", use: ExecRoute.createExec(client: client))
        routes.get(":version", "exec", ":id", "json", use: ExecRoute.inspectExec(client: client))
        routes.get("exec", ":id", "json", use: ExecRoute.inspectExec(client: client))
        routes.post(":version", "exec", ":id", "start", use: ExecRoute.startExec(client: client))
        routes.post("exec", ":id", "start", use: ExecRoute.startExec(client: client))
        routes.post(":version", "exec", ":id", "resize", use: ExecRoute.resize(client: client))
        routes.post("exec", ":id", "resize", use: ExecRoute.resize(client: client))
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

            // For simplicity, we'll assume the exec is not running if we can inspect it
            // In a real implementation, you'd track the actual process state
            let response = ExecInspectResponse(
                ID: execId,
                Running: false,  // We'd need to track this properly
                ExitCode: nil,  // We'd need to track this from the actual process
                ProcessConfig: ExecInspectResponse.ProcessConfigInfo(
                    privileged: false,
                    user: "",
                    tty: config.tty,
                    entrypoint: config.cmd.first ?? "",
                    arguments: Array(config.cmd.dropFirst()),
                    workingDir: "",
                    env: []
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
                detach: false
            )

            let id = await ExecManager.shared.create(config: config)
            return Response(status: .created, body: .init(data: try JSONEncoder().encode(CreateExecResponse(Id: id))))
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

                let process = try await container.createProcess(
                    id: UUID().uuidString.lowercased(),
                    configuration: processConfig,
                    stdio: [nil, nil, nil]
                )
                try await process.start()
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

                    let process = try await container.createProcess(
                        id: UUID().uuidString.lowercased(),
                        configuration: processConfig,
                        stdio: stdio.asArray
                    )

                    try await process.start()

                    await withTaskGroup(of: Void.self) { group in
                        // stdout handler
                        if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                            group.addTask {
                                while true {
                                    do {
                                        guard let data = try stdoutHandle.read(upToCount: 4096), !data.isEmpty else {
                                            break
                                        }

                                        var buffer = ByteBufferAllocator().buffer(capacity: data.count + (tty ? 0 : 8))
                                        buffer.writeDockerFrame(streamType: .stdout, data: data, ttyMode: tty)
                                        streamContinuation.yield(buffer)
                                    } catch {
                                        break
                                    }
                                }
                                try? stdoutHandle.close()
                            }
                        }

                        // stderr handler
                        if let stderrHandle = stderrPipe?.fileHandleForReading {
                            group.addTask {
                                while true {
                                    do {
                                        guard let data = try stderrHandle.read(upToCount: 4096), !data.isEmpty else {
                                            break
                                        }

                                        var buffer = ByteBufferAllocator().buffer(capacity: data.count + 8)
                                        buffer.writeDockerFrame(streamType: .stderr, data: data, ttyMode: tty)
                                        streamContinuation.yield(buffer)
                                    } catch {
                                        break
                                    }
                                }
                                try? stderrHandle.close()
                            }
                        }

                        // stdin handler for HTTP mode
                        if let stdinWriter = stdinPipe?.fileHandleForWriting {
                            group.addTask {
                                do {
                                    for try await var buf in req.body {
                                        if let data = buf.readData(length: buf.readableBytes) {
                                            try stdinWriter.write(contentsOf: data)
                                        }
                                    }
                                } catch {
                                }
                                try? stdinWriter.close()
                            }
                        }

                        // Process monitor
                        group.addTask {
                            do {
                                let _ = try await process.wait()
                            } catch {
                            }

                            // Close all write ends to signal EOF
                            try? stdoutPipe?.fileHandleForWriting.close()
                            try? stderrPipe?.fileHandleForWriting.close()
                            try? stdinPipe?.fileHandleForWriting.close()
                        }

                        for await _ in group {}
                    }

                    await ExecManager.shared.remove(id: execId)
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

                let process = try await container.createProcess(
                    id: UUID().uuidString.lowercased(),
                    configuration: processConfig,
                    stdio: stdio.asArray
                )

                try await process.start()

                // Setup bidirectional communication for interactive sessions
                await withTaskGroup(of: Void.self) { group in
                    // stdout/stderr -> channel (container output to client)
                    if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                        group.addTask {
                            let dispatchIO = DispatchIO(
                                type: .stream,
                                fileDescriptor: stdoutHandle.fileDescriptor,
                                queue: DispatchQueue.global(qos: .userInteractive)
                            ) { error in
                                // Handle cleanup error if needed
                            }

                            // Set up for streaming - read in small chunks with low water mark
                            dispatchIO.setLimit(lowWater: 1)
                            dispatchIO.setLimit(highWater: 4096)

                            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                                var isFinished = false
                                var hasResumed = false

                                func readNextChunk() {
                                    guard !isFinished else { return }

                                    dispatchIO.read(
                                        offset: off_t.max,  // Use off_t.max for streaming (current position)
                                        length: 4096,
                                        queue: DispatchQueue.global(qos: .userInteractive)
                                    ) { done, data, error in

                                        if let data = data, !data.isEmpty {
                                            // Send data to channel immediately
                                            channel.eventLoop.execute {
                                                var outputBuffer = channel.allocator.buffer(capacity: data.count + (tty ? 0 : 8))
                                                if tty {
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
                                            // Continue reading immediately for streaming
                                            readNextChunk()
                                        }
                                    }
                                }

                                // Start reading
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
                                // Handle cleanup error if needed
                            }

                            // Set up for streaming
                            dispatchIO.setLimit(lowWater: 1)
                            dispatchIO.setLimit(highWater: 1024)

                            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                                var isFinished = false
                                var hasResumed = false

                                func readNextChunk() {
                                    guard !isFinished else { return }

                                    dispatchIO.read(
                                        offset: off_t.max,  // Streaming mode
                                        length: 1024,
                                        queue: DispatchQueue.global(qos: .userInteractive)
                                    ) { done, data, error in

                                        if let data = data, !data.isEmpty {
                                            channel.eventLoop.execute {
                                                var outputBuffer = channel.allocator.buffer(capacity: data.count + 8)
                                                outputBuffer.writeDockerFrame(streamType: .stderr, data: Data(data), ttyMode: tty)
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
                            let _ = try await process.wait()
                        } catch {
                            // Process wait error - handle gracefully
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

                await ExecManager.shared.remove(id: execId)
            }
        }
    }

    static func resize(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
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

            let _ = (try? req.query.get(Int.self, at: "h")) ?? 24
            let _ = (try? req.query.get(Int.self, at: "w")) ?? 80

            // Note: ContainerClient does not currently support resizing exec processes.
            // This is a placeholder for future implementation.
            // try await exec.resize(height: height, width: width)

            return Response(status: .ok)
        }
    }

}
