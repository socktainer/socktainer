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

            // moby: MuxStreams=false — WebSocket is the mux; raw binary frames,
            // no stdcopy header, matches moby's wsContainersAttach behaviour.
            return req.webSocket { req, ws in
                Task {
                    if container.status == .stopped {
                        await handleStopped(
                            ws: ws, req: req, hexId: id, container: container, query: query)
                    } else {
                        await handleRunning(ws: ws, req: req, container: container, query: query)
                    }
                }
            }
        }
    }

    // MARK: - Stopped container (bootstrap with pipes — same lifecycle as HTTP attach)

    private static func handleStopped(
        ws: WebSocket,
        req: Request,
        hexId: String,
        container: ContainerSnapshot,
        query: ContainerAttachWSQuery
    ) async {
        let stdin = query.stdin ?? false
        let stdout = query.stdout ?? true
        let stderr = query.stderr ?? true
        let isTTY = container.configuration.initProcess.terminal

        await ContainerStartRoute.ensureDNSSidecarBeforeStart(for: container, req: req)

        guard let pipes = StdioPipes.make(stdin: true, stdout: stdout, stderr: stderr && !isTTY) else {
            try? await ws.close(code: .unexpectedServerError)
            return
        }

        // For non-interactive containers, pre-close the write end so the container
        // sees immediate stdin EOF. ws.onClose (registered below) calls close() on
        // the same FileHandle object — Foundation makes that second call a no-op.
        if !stdin {
            try? pipes.stdin?.write.close()
        }

        // ws.onClose is the sole owner for the interactive stdin write end.
        // For non-interactive, the pre-close above already happened — this is a
        // safe no-op second call on the same FileHandle object.
        ws.onClose.whenComplete { _ in
            try? pipes.stdin?.write.close()
        }

        await ContainerExitCodeStore.shared.remove(id: container.id)

        let process: ClientProcess
        do {
            process = try await ContainerClient().bootstrap(id: container.id, stdio: pipes.stdioArray)
        } catch {
            pipes.closeAll()
            await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
            await ContainerExitCodeStore.shared.set(id: hexId, code: -1)
            try? await ws.close(code: .unexpectedServerError)
            return
        }

        do {
            try await process.start()
        } catch {
            if !isBenignStartRace(error) {
                pipes.closeAfterHandoff()
                await ContainerExitCodeStore.shared.set(id: container.id, code: -1)
                await ContainerExitCodeStore.shared.set(id: hexId, code: -1)
                try? await ws.close(code: .unexpectedServerError)
                return
            }
        }

        await ProcessRegistry.shared.set(id: container.id, process: process)

        // Wire WS → stdin. Guard ws.isClosed so a late-arriving frame after
        // teardown doesn't write to a closed fd.
        if stdin {
            let stdinWriter = pipes.stdin!.write
            ws.onBinary { ws, buf in
                guard !ws.isClosed else { return }
                var b = buf
                if let data = b.readBytes(length: b.readableBytes) {
                    try? stdinWriter.write(contentsOf: data)
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            // Process monitor — sole owner of teardown (no double-close with ws.onClose
            // because ws.onClose only closes the stdin write end, not the read ends).
            group.addTask {
                _ = await ContainerProcessExitMonitor.run(
                    wait: { try await process.wait() },
                    hexId: hexId,
                    nativeId: container.id,
                    fallbackImage: container.configuration.image.reference,
                    fallbackLabels: LabelNormalization.restore(container.configuration.labels),
                    dnsServer: req.application.storage[SocktainerDNSServerKey.self],
                    broadcaster: req.application.storage[EventBroadcasterKey.self]
                )

                try? await ws.close()
            }

            // Stdout → WS binary frames. Break on send error (client disconnected).
            if let stdoutHandle = pipes.stdout?.read {
                group.addTask {
                    defer { try? stdoutHandle.close() }
                    while let data = try? stdoutHandle.read(upToCount: 8192), !data.isEmpty {
                        do {
                            try await ws.send(raw: data, opcode: .binary)
                        } catch {
                            break
                        }
                    }
                }
            }

            // Stderr → WS binary frames (non-TTY + both streams requested).
            if let stderrHandle = pipes.stderr?.read {
                group.addTask {
                    defer { try? stderrHandle.close() }
                    while let data = try? stderrHandle.read(upToCount: 8192), !data.isEmpty {
                        do {
                            try await ws.send(raw: data, opcode: .binary)
                        } catch {
                            break
                        }
                    }
                }
            }

            for await _ in group {}
        }
    }

    // MARK: - Running container (stream log output)

    private static func handleRunning(
        ws: WebSocket,
        req: Request,
        container: ContainerSnapshot,
        query: ContainerAttachWSQuery
    ) async {
        let stream = query.stream ?? false
        let logs = query.logs ?? false

        // Fix: reject degenerate requests with neither stream nor logs, matching
        // the HTTP attach guard (ContainerAttachRoute line 76-78).
        guard stream || logs else {
            try? await ws.close()
            return
        }

        // Wait for the log file, escaping when the WS closes or after ~10s.
        // The timeout guards against an indefinite poll when a container is
        // removed via another API call while the WS is still open.
        var logHandle: FileHandle? = nil
        var attempts = 0
        let maxAttempts = 200  // 200 × 50 ms = 10 s
        while logHandle == nil {
            guard !ws.isClosed, attempts < maxAttempts else {
                try? await ws.close()
                return
            }
            attempts += 1
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

        let containerClient = ContainerClient()

        // Drain buffered output, breaking on client disconnect.
        while !ws.isClosed, let data = try? fileHandle.read(upToCount: 4096), !data.isEmpty {
            do {
                try await ws.send(raw: data, opcode: .binary)
            } catch {
                try? await ws.close()
                return
            }
        }

        // Follow live output. Break on disconnect or container stop.
        while stream, !ws.isClosed {
            if let data = try? fileHandle.read(upToCount: 4096), !data.isEmpty {
                do {
                    try await ws.send(raw: data, opcode: .binary)
                } catch {
                    break
                }
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

}
