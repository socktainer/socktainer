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

            // moby validates the stream parameters before resolving the container:
            // a request that attaches to neither stream is a 400. The docker CLI
            // always sends stdout=1&stderr=1, so neither is a client error, not a
            // request for the default.
            let wantStdout = MobyBool.queryValue(req.query["stdout"] as String?)
            let wantStderr = MobyBool.queryValue(req.query["stderr"] as String?)
            guard wantStdout || wantStderr else {
                throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
            }

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            // `tail=<N>` limits the backlog to the last N lines; "all" (the
            // default) or an unparseable value streams the whole backlog.
            let tail = ContainerLogsRoute.parseTail(req.query["tail"] as String?)

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
            let follow = MobyBool.queryValue(req.query["follow"] as String?)
            let timestamps = MobyBool.queryValue(req.query["timestamps"] as String?)

            let body = Response.Body { writer in
                Task.detached {
                    var buffer = Data()

                    // Flushes any trailing line left in `buffer` with no terminating
                    // newline yet, then closes out the response. Only call this once
                    // the stream has genuinely ended — flushing on a mid-stream read
                    // gap could stamp and emit a line the writer hasn't finished yet.
                    func finish() {
                        ContainerLogsRoute.flushFinalLogLine(buffer, ttyMode: isTTY, timestamps: timestamps) { outputBuffer in
                            _ = writer.write(.buffer(outputBuffer))
                        }
                        try? fileHandle.close()
                        _ = writer.write(.end)
                    }

                    do {
                        if let tail {
                            // Apple Container's log API is a forward byte stream with
                            // no reverse-seek. Read it through, keeping only the last
                            // `tail` lines so memory stays bounded to ~2x tail lines
                            // rather than the whole (unrotated) log.
                            let backlog = try ContainerLogsRoute.tailBacklog(tail: tail) { try fileHandle.read(upToCount: 4096) }
                            var frames: [ByteBuffer] = []
                            buffer = ContainerLogsRoute.processDockerLogFrames(from: backlog, ttyMode: isTTY, timestamps: timestamps) { outputBuffer in
                                frames.append(outputBuffer)
                            }
                            // Await each write so a client disconnect aborts the
                            // response instead of queueing the whole window (the
                            // same contract as the follow loop below).
                            for frame in frames {
                                do {
                                    try await writer.write(.buffer(frame)).get()
                                } catch {
                                    finish()
                                    return
                                }
                            }
                        } else {
                            // Read initial logs
                            while true {
                                let data = try fileHandle.read(upToCount: 4096)
                                guard let data, !data.isEmpty else { break }
                                buffer.append(data)

                                // Process complete frames from buffer
                                buffer = ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: isTTY, timestamps: timestamps) { outputBuffer in
                                    _ = writer.write(.buffer(outputBuffer))
                                }
                            }
                        }

                        if !follow {
                            finish()
                            return
                        }
                    } catch {
                        finish()
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
                                buffer = ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: isTTY, timestamps: timestamps) { outputBuffer in
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
                    finish()
                }
            }

            return Response(
                status: .ok,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: body
            )
        }
    }

    /// Parses moby's `tail` query value. "all", an absent value, or anything
    /// non-numeric means the whole backlog (nil); a non-negative integer means
    /// only that many trailing lines.
    static func parseTail(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.lowercased() != "all" else { return nil }
        guard let n = Int(value), n >= 0 else { return nil }
        return n
    }

    /// Returns only the last `count` newline-delimited lines of `data`. A
    /// trailing line with no terminating newline still counts as a line, and a
    /// single trailing newline is not treated as an extra empty line. `count == 0`
    /// yields no output.
    /// Reads a stream through chunk by chunk via `read` (nil or empty means
    /// EOF) and returns only its last `tail` lines. The window is trimmed once
    /// it holds twice the wanted lines, not on every chunk, so each byte is
    /// scanned O(1) times amortized even for a huge `tail` over a huge log.
    static func tailBacklog(tail: Int, read: () throws -> Data?) rethrows -> Data {
        var backlog = Data()
        var newlines = 0
        let trimAt = max(tail, 1) > Int.max / 2 ? Int.max : max(tail, 1) * 2
        while let data = try read(), !data.isEmpty {
            newlines += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            backlog.append(data)
            if newlines >= trimAt {
                backlog = lastLines(backlog, count: tail)
                newlines = tail
            }
        }
        return lastLines(backlog, count: tail)
    }

    static func lastLines(_ data: Data, count: Int) -> Data {
        guard count > 0 else { return Data() }
        guard !data.isEmpty else { return data }
        // Ignore one trailing newline so "a\nb\n" with count 1 yields "b\n".
        var searchEnd = data.endIndex
        if data.last == 0x0A { searchEnd = data.index(before: data.endIndex) }
        var seen = 0
        var i = searchEnd
        while i > data.startIndex {
            let prev = data.index(before: i)
            if data[prev] == 0x0A {
                seen += 1
                if seen == count { return Data(data[i...]) }
            }
            i = prev
        }
        return data
    }

    static func processDockerLogFrames(from buffer: Data, ttyMode: Bool, timestamps: Bool = false, writeOutput: (ByteBuffer) -> Void) -> Data {
        guard !buffer.isEmpty else {
            return buffer
        }

        guard timestamps else {
            emitFrame(buffer, ttyMode: ttyMode, writeOutput: writeOutput)
            return Data()
        }

        // Real Docker stamps each line with the time it was written. Apple Container's
        // log API is a raw byte stream with no per-line write-time metadata, so every
        // complete line found in this pass is stamped with the same "now" value instead
        // — reasonably accurate for live follow tailing (within the ~150ms poll
        // interval), but a non-follow read of already-buffered historical output gets
        // every line stamped with the same read-time value, since the true write time
        // isn't recoverable on this platform. A trailing line with no newline yet is
        // left in the returned remainder so it isn't stamped and framed prematurely.
        let prefix = timestampPrefix()
        var remaining = buffer
        while let newlineIndex = remaining.firstIndex(of: 0x0A) {
            let line = prefix + remaining[remaining.startIndex...newlineIndex]
            remaining = remaining[remaining.index(after: newlineIndex)...]
            emitFrame(line, ttyMode: ttyMode, writeOutput: writeOutput)
        }
        return Data(remaining)
    }

    /// Stamps and frames a trailing line left over with no terminating newline —
    /// called once the stream has genuinely ended, not on a mid-stream read gap that
    /// might just mean the writer hasn't flushed the rest of the line yet.
    static func flushFinalLogLine(_ buffer: Data, ttyMode: Bool, timestamps: Bool, writeOutput: (ByteBuffer) -> Void) {
        guard timestamps, !buffer.isEmpty else { return }
        emitFrame(timestampPrefix() + buffer, ttyMode: ttyMode, writeOutput: writeOutput)
    }

    private static func timestampPrefix() -> Data {
        Data("\(AppleContainerTimestampResolver.iso8601Timestamp(Date())) ".utf8)
    }

    /// Match the container's TTY mode: a TTY produces a raw, unmultiplexed stream, while
    /// non-TTY logs use Docker's 8-byte stdcopy framing. Shared with the attach/exec routes
    /// via writeDockerFrame so the wire format is defined in exactly one place.
    private static func emitFrame(_ data: Data, ttyMode: Bool, writeOutput: (ByteBuffer) -> Void) {
        var outputBuffer = ByteBufferAllocator().buffer(capacity: data.count + (ttyMode ? 0 : 8))
        outputBuffer.writeDockerFrame(streamType: .stdout, data: data, ttyMode: ttyMode)
        writeOutput(outputBuffer)
    }
}
