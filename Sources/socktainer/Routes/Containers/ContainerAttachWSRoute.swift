import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation
import Vapor

private struct ContainerAttachWSQuery: Content {
    let logs: Bool?
    let stream: Bool?
    let stdin: Bool?
    let stdout: Bool?
    let stderr: Bool?
    let detachKeys: String?
}

struct ContainerAttachWSRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/containers/{id}/attach/ws",
            use: ContainerAttachWSRoute.handler(client: client))
    }
}

extension ContainerAttachWSRoute {

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let query = try req.query.decode(ContainerAttachWSQuery.self)
            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            // moby: MuxStreams=false — WebSocket is the mux; stdout and stderr are
            // sent as raw binary frames on the same connection, no stdcopy header.
            return req.webSocket { req, ws in
                Task {
                    if container.status == .stopped {
                        await handleStopped(ws: ws, req: req, container: container, query: query)
                    } else {
                        await handleRunning(ws: ws, req: req, container: container, query: query)
                    }
                }
            }
        }
    }

    // MARK: - Stopped container (bootstrap with pipes — same as HTTP attach)

    private static func handleStopped(
        ws: WebSocket,
        req: Request,
        container: ContainerSnapshot,
        query: ContainerAttachWSQuery
    ) async {
        let stdin = query.stdin ?? false
        let stdout = query.stdout ?? true
        let stderr = query.stderr ?? true
        let isTTY = container.configuration.initProcess.terminal

        let stdinPipe = Pipe()
        let stdoutPipe: Pipe? = stdout ? Pipe() : nil
        let stderrPipe: Pipe? = (stderr && !isTTY) ? Pipe() : nil

        let stdio: [FileHandle?] = [
            stdinPipe.fileHandleForReading,
            stdoutPipe?.fileHandleForWriting,
            stderrPipe?.fileHandleForWriting,
        ]

        if !stdin {
            try? stdinPipe.fileHandleForWriting.close()
        }

        await ContainerExitCodeStore.shared.remove(id: container.id)

        let process: ClientProcess
        do {
            process = try await ContainerClient().bootstrap(id: container.id, stdio: stdio)
        } catch {
            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
            try? await ws.close(code: .unexpectedServerError)
            return
        }

        do {
            try await process.start()
        } catch {
            if !isBenignStartRace(error) {
                await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
                try? await ws.close(code: .unexpectedServerError)
                return
            }
        }

        await ProcessRegistry.shared.set(id: container.id, process: process)

        // Wire WS → stdin (client sends binary frames → container stdin).
        if stdin {
            let stdinWriter = stdinPipe.fileHandleForWriting
            ws.onBinary { _, buf in
                var b = buf
                if let data = b.readBytes(length: b.readableBytes) {
                    try? stdinWriter.write(contentsOf: data)
                }
            }
        }

        // Teardown shared between process-exit and WS-close paths.
        let cleanup: @Sendable () async -> Void = {
            try? stdoutPipe?.fileHandleForWriting.close()
            try? stderrPipe?.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForReading.close()
        }

        ws.onClose.whenComplete { _ in
            // Client disconnected — release the process gracefully.
            Task { await cleanup() }
        }

        await withTaskGroup(of: Void.self) { group in
            // Process monitor: wait for exit, propagate exit code, close WS.
            group.addTask {
                let code = (try? await process.wait()) ?? 0
                await ProcessRegistry.shared.remove(id: container.id)
                await cleanup()
                try? await Task.sleep(nanoseconds: ContainerAttachRoute.outputFlushGraceNs)
                await ContainerExitCodeStore.shared.set(id: container.id, code: code)
                try? await ws.close()
            }

            // Stdout → WS binary frames (raw, no Docker multiplexing header).
            if let stdoutHandle = stdoutPipe?.fileHandleForReading {
                group.addTask {
                    defer { try? stdoutHandle.close() }
                    while let data = try? stdoutHandle.read(upToCount: 8192), !data.isEmpty {
                        try? await ws.send(raw: data, opcode: .binary)
                    }
                }
            }

            // Stderr → WS binary frames (separate when non-TTY + both streams).
            if let stderrHandle = stderrPipe?.fileHandleForReading {
                group.addTask {
                    defer { try? stderrHandle.close() }
                    while let data = try? stderrHandle.read(upToCount: 8192), !data.isEmpty {
                        try? await ws.send(raw: data, opcode: .binary)
                    }
                }
            }

            for await _ in group {}
        }
    }

    // MARK: - Running container (stream log output, no stdin)

    private static func handleRunning(
        ws: WebSocket,
        req: Request,
        container: ContainerSnapshot,
        query: ContainerAttachWSQuery
    ) async {
        let stream = query.stream ?? false

        // Wait until the log file is available.
        var logHandle: FileHandle? = nil
        while logHandle == nil {
            if let fhs = try? await ContainerClient().logs(id: container.id), !fhs.isEmpty {
                logHandle = fhs[0]
                if fhs.count > 1 { try? fhs[1].close() }
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let fileHandle = logHandle else {
            try? await ws.close()
            return
        }
        defer { try? fileHandle.close() }

        ws.onClose.whenComplete { _ in }  // nothing special needed for running containers

        let containerClient = ContainerClient()
        while let data = try? fileHandle.read(upToCount: 4096), !data.isEmpty {
            try? await ws.send(raw: data, opcode: .binary)
        }
        while stream {
            if let data = try? fileHandle.read(upToCount: 4096), !data.isEmpty {
                try? await ws.send(raw: data, opcode: .binary)
            } else {
                let current = try? await containerClient.get(id: container.id)
                if current == nil || current?.status != .running {
                    if let flush = try? fileHandle.read(upToCount: 4096), !flush.isEmpty {
                        try? await ws.send(raw: flush, opcode: .binary)
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        try? await ws.close()
    }

    // MARK: - Shared helpers

    private static func isBenignStartRace(_ error: Error) -> Bool {
        let msg = error.localizedDescription
        return msg.contains("booted") || msg.contains("expected to be in created state")
    }
}
