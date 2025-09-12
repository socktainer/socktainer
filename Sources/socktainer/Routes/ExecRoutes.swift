import ContainerClient
import Foundation
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
        routes.get(":version", "exec", ":id", "json",use: ExecRoute.inspectExec(client: client))
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
                Running: false, // We'd need to track this properly
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
        let consoleSize = startRequest.ConsoleSize ?? [24, 80]

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

        // Attached mode
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

        let body = Response.Body(stream: { writer in
            Task.detached {
                @Sendable func writeFrame(streamType: UInt8, data: Data) {
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count + (tty ? 0 : 8))
                    if tty {
                        buffer.writeBytes(data)
                    } else {
                        let size = UInt32(data.count)
                        var header = Data(capacity: 8)
                        header.append(streamType)
                        header.append(0)
                        header.append(0)
                        header.append(0)
                        header.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Data($0) })
                        buffer.writeBytes(header)
                        buffer.writeBytes(data)
                    }
                    _ = writer.write(.buffer(buffer))
                }

                await withTaskGroup(of: Void.self) { group in

                    // stdout
                    if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                        group.addTask {
                            while true {
                                do {
                                    if let data = try stdoutHandle.read(upToCount: 4096), !data.isEmpty {
                                        writeFrame(streamType: 1, data: data)
                                        /*if let text = String(data: data, encoding: .utf8) {
                                             print("[Exec \(execId) stdout] \(text)", terminator: "")
                                        }*/
                                    } else {
                                        break
                                    }
                                } catch {
                                    // print("[Exec \(execId) stdout] read error: \(error)")
                                    break
                                }
                            }
                            // print("[Exec \(execId) stdout] finished")
                            try? stdoutHandle.close()
                        }
                    }

                    // stderr
                    if let stderrHandle = stderrPipe?.fileHandleForReading {
                        group.addTask {
                            while true {
                                do {
                                    if let data = try stderrHandle.read(upToCount: 4096), !data.isEmpty {
                                        writeFrame(streamType: 2, data: data)
                                        /*if let text = String(data: data, encoding: .utf8) {
                                            print("[Exec \(execId) stderr] \(text)", terminator: "")
                                        }*/
                                    } else {
                                        break
                                    }
                                } catch {
                                    // print("[Exec \(execId) stderr] read error: \(error)")
                                    break
                                }
                            }
                            // print("[Exec \(execId) stderr] finished")
                            try? stderrHandle.close()
                        }
                    }

                    // stdin
                    if let stdinWriter = stdinPipe?.fileHandleForWriting {
                        group.addTask {
                            do {
                                for try await var buf in req.body {
                                    if let data = buf.readData(length: buf.readableBytes) {
                                        try stdinWriter.write(contentsOf: data)
                                    }
                                }
                            } catch {
                                // print("[Exec \(execId) stdin] Error: \(error)")
                            }
                            try? stdinWriter.close()
                            // print("[Exec \(execId) stdin] finished")
                        }
                    }

                    // Monitor process and close all write ends immediately
                    group.addTask {
                        do {
                            let exitCode = try await process.wait()
                            // print("Process \(execId) finished with exit code: \(exitCode)")
                        } catch {
                            // print("Process \(execId) finished with error: \(error)")
                        }

                        // CLOSE ALL WRITE ENDS TO SIGNAL EOF
                        try? stdoutPipe?.fileHandleForWriting.close()
                        try? stderrPipe?.fileHandleForWriting.close()
                        try? stdinPipe?.fileHandleForWriting.close()
                        // print("[Exec \(execId)] all write ends closed")
                    }

                    for await _ in group {}
                }

                await ExecManager.shared.remove(id: execId)
                _ = writer.write(.end)
            }
        })

        // Set headers
        var headers: HTTPHeaders = [:]
        headers.add(name: "Content-Type", value: tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")

        if req.headers.first(name: "Connection")?.lowercased().contains("upgrade") == true &&
           req.headers.first(name: "Upgrade")?.lowercased() == "tcp" {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
            return Response(status: .switchingProtocols, headers: headers, body: body)
        }

        return Response(status: .ok, headers: headers, body: body)
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

            let height = (try? req.query.get(Int.self, at: "h")) ?? 24
            let width = (try? req.query.get(Int.self, at: "w")) ?? 80

           // Note: ContainerClient does not currently support resizing exec processes.
            // This is a placeholder for future implementation.
            // try await exec.resize(height: height, width: width)

            return Response(status: .ok)
        }
    }

}
