import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Vapor

/// Thread-safe state management for Docker I/O operations to prevent race conditions
public final class DockerConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isFinished = false
    private var _hasResumed = false

    public init() {}

    public func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isFinished
    }

    public func finish(completion: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if !_hasResumed {
            _isFinished = true
            _hasResumed = true
            completion()
        }
    }
}

/// Shared allocator for memory efficiency across Docker operations
public let sharedAllocator = ByteBufferAllocator()

/// Low-level pipe pair created via pipe(2) with closeOnDealloc:false.
///
/// **Prefer `StdioPipes`** for all container stdio wiring — it handles EMFILE
/// validation and provides `closeAll()` / `closeAfterHandoff()` so every error
/// path is covered without manual per-fd calls. `ProcessPipe` is an
/// implementation detail exposed only for testing the raw fd ownership contract.
///
/// Ownership model:
///   - stdout/stderr: pass `.write` to createProcess/bootstrap; Apple owns that close.
///     Caller explicitly closes `.read` when the reader task finishes.
///   - stdin: pass `.read` to createProcess/bootstrap; Apple owns that close.
///     Caller explicitly closes `.write` when done writing.
struct ProcessPipe: @unchecked Sendable {
    let read: FileHandle
    let write: FileHandle

    static func make() -> ProcessPipe? {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { return nil }
        return ProcessPipe(
            read: FileHandle(fileDescriptor: fds[0], closeOnDealloc: false),
            write: FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        )
    }
}

/// Collects the three stdio pipe pairs for a container process, with centralised
/// allocation, validation, and cleanup that eliminates per-call-site boilerplate
/// and prevents fd leaks on every error path.
///
/// Ownership after `createProcess(stdio:)` / `bootstrap(id:stdio:)`:
///   - Apple owns and will close: `stdin?.read`, `stdout?.write`, `stderr?.write`
///   - Caller owns and must close: `stdin?.write`, `stdout?.read`, `stderr?.read`
///
/// Usage pattern:
/// ```swift
/// guard let pipes = StdioPipes.make([.stdin, .stdout, .stderr]) else {
///     throw Abort(.internalServerError, reason: "Failed to create I/O pipes")
/// }
/// let process: ClientProcess
/// do {
///     process = try await ContainerClient().createProcess(..., stdio: pipes.stdioArray)
/// } catch {
///     pipes.closeAll()   // Apple never took ownership
///     throw error
/// }
/// do {
///     try await process.start()
/// } catch {
///     pipes.closeAfterHandoff()   // Apple owns the passed ends
///     throw error
/// }
/// ```
struct StdioPipes: @unchecked Sendable {

    /// Which stdio channels to allocate. Use as an OptionSet:
    ///   `StdioPipes.make([.stdout, .stderr])`  or  `StdioPipes.make(.all)`
    struct Channels: OptionSet {
        let rawValue: UInt8
        static let stdin = Channels(rawValue: 1 << 0)
        static let stdout = Channels(rawValue: 1 << 1)
        static let stderr = Channels(rawValue: 1 << 2)
        static let all: Channels = [.stdin, .stdout, .stderr]
    }

    let stdin: ProcessPipe?
    let stdout: ProcessPipe?
    let stderr: ProcessPipe?

    /// `[stdin.read, stdout.write, stderr.write]` — the array to pass to createProcess/bootstrap.
    var stdioArray: [FileHandle?] { [stdin?.read, stdout?.write, stderr?.write] }

    /// Allocates pipes for the requested channels. Returns `nil` (and closes any
    /// partially-allocated pipes) if any required pipe cannot be created (EMFILE).
    ///
    /// Prefer the OptionSet overload for static channel selection:
    ///   `StdioPipes.make([.stdout, .stderr])`  or  `StdioPipes.make(.all)`
    /// Use the Bool overload (`make(stdin:stdout:stderr:)`) when channels are
    /// computed dynamically from config flags.
    ///
    /// The `makePipe` parameter defaults to `ProcessPipe.make` and exists solely
    /// as a test seam — inject a custom factory to exercise the partial-allocation
    /// cleanup path without exhausting process-wide file descriptors.
    static func make(_ channels: Channels, makePipe: () -> ProcessPipe? = ProcessPipe.make) -> StdioPipes? {
        let stdinPipe = channels.contains(.stdin) ? makePipe() : nil
        let stdoutPipe = channels.contains(.stdout) ? makePipe() : nil
        let stderrPipe = channels.contains(.stderr) ? makePipe() : nil

        let allOk =
            (!channels.contains(.stdin) || stdinPipe != nil)
            && (!channels.contains(.stdout) || stdoutPipe != nil)
            && (!channels.contains(.stderr) || stderrPipe != nil)

        guard allOk else {
            try? stdinPipe?.read.close()
            try? stdinPipe?.write.close()
            try? stdoutPipe?.read.close()
            try? stdoutPipe?.write.close()
            try? stderrPipe?.read.close()
            try? stderrPipe?.write.close()
            return nil
        }
        return StdioPipes(stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
    }

    /// Convenience overload for dynamic channel selection from boolean config flags.
    /// Use the OptionSet overload for static cases: `make([.stdout, .stderr])`.
    static func make(stdin: Bool, stdout: Bool, stderr: Bool) -> StdioPipes? {
        var channels: Channels = []
        if stdin { channels.insert(.stdin) }
        if stdout { channels.insert(.stdout) }
        if stderr { channels.insert(.stderr) }
        return make(channels)
    }

    /// Close all six fds. Use when createProcess/bootstrap has NOT yet taken ownership
    /// (e.g. the call threw before completing the dup).
    func closeAll() {
        try? stdin?.read.close()
        try? stdin?.write.close()
        try? stdout?.read.close()
        try? stdout?.write.close()
        try? stderr?.read.close()
        try? stderr?.write.close()
    }

    /// Close the fds we retain after createProcess/bootstrap has taken ownership:
    /// `stdin?.write`, `stdout?.read`, `stderr?.read`.
    ///
    /// Safe to call even when `stdin?.write` was already closed (e.g. pre-closed
    /// for non-interactive attach) — `FileHandle.close()` is idempotent on the
    /// same object.
    func closeAfterHandoff() {
        try? stdin?.write.close()
        try? stdout?.read.close()
        try? stderr?.read.close()
    }

    /// Collect stdout and stderr as `Data` while concurrently waiting for the
    /// process via `wait`. Draining must happen before waiting: if the child
    /// writes more than the pipe buffer holds it blocks on write, so calling
    /// `wait` first would deadlock.
    ///
    /// On error the wait closure's error is rethrown immediately. The drain
    /// tasks continue in the background and exit naturally when the process
    /// exits and Apple closes the write ends.
    ///
    /// - Parameter wait: async closure that waits for the process and returns
    ///   its exit code (e.g. `{ try await process.wait() }`).
    func collectOutput(waiting wait: () async throws -> Int32) async throws -> (
        exitCode: Int32, stdout: Data, stderr: Data
    ) {
        let stdoutReader = stdout?.read
        let stderrReader = stderr?.read

        // `read(upToCount:)` loop is used instead of `readDataToEndOfFile()` /
        // `readToEnd()`. Both of those can raise NSException when the fd is
        // closed from the error path below. `read(upToCount:)` returns nil on
        // EBADF (swallowed by `try?`), which cleanly breaks the loop.
        let stdoutTask = Task.detached { () -> Data in
            defer { try? stdoutReader?.close() }
            var data = Data()
            while let chunk = try? stdoutReader?.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
            }
            return data
        }
        let stderrTask = Task.detached { () -> Data in
            defer { try? stderrReader?.close() }
            var data = Data()
            while let chunk = try? stderrReader?.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
            }
            return data
        }

        do {
            let code = try await wait()
            return (code, await stdoutTask.value, await stderrTask.value)
        } catch {
            // Do NOT close read ends here — concurrent close(2) + read(2) on the same
            // fd is unsafe and can raise NSException. The drain tasks will exit on
            // their own once the process fully exits and Apple closes the write ends.
            // We rethrow immediately rather than awaiting them.
            throw error
        }
    }
}

/// This provides TCP connection hijacking for Docker exec endpoints
public struct DockerTCPUpgrader: Upgrader, Sendable {
    let execId: String
    let ttyEnabled: Bool
    let streamHandler: @Sendable (Channel, DockerTCPHandler) async throws -> Void

    public init(execId: String, ttyEnabled: Bool, streamHandler: @escaping @Sendable (Channel, DockerTCPHandler) async throws -> Void) {
        self.execId = execId
        self.ttyEnabled = ttyEnabled
        self.streamHandler = streamHandler
    }

    public func applyUpgrade(req: Request, res: Response) -> HTTPServerProtocolUpgrader {
        DockerTCPProtocolUpgrader(
            execId: execId,
            ttyEnabled: ttyEnabled,
            streamHandler: streamHandler
        )
    }
}

/// Internal protocol upgrader that handles the actual NIO channel upgrade for Docker TCP
private struct DockerTCPProtocolUpgrader: HTTPServerProtocolUpgrader {
    let execId: String
    let ttyEnabled: Bool
    let streamHandler: @Sendable (Channel, DockerTCPHandler) async throws -> Void

    var supportedProtocol: String { "tcp" }
    var requiredUpgradeHeaders: [String] { ["upgrade"] }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {

        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "Upgrade")
        headers.add(name: "Upgrade", value: "tcp")

        return channel.eventLoop.makeSucceededFuture(headers)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {

        let tcpHandler = DockerTCPHandler(execId: execId, ttyEnabled: ttyEnabled)

        let channel = context.channel
        let eventLoop = context.eventLoop
        let pipeline = context.pipeline

        // Allow the remote peer to half-close its write side (stdin EOF) without
        // tearing down the whole channel. Without this, Docker CLI piping stdin
        // (echo "hi" | docker run -i ...) closes the write half after sending data,
        // which NIO interprets as a full close — the channel goes away before
        // stdout can be sent back. With this option NIO fires .inputClosed instead.
        return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            pipeline.addHandler(tcpHandler).flatMap { _ in
                _ = Task.detached { [streamHandler] in
                    do {
                        try await streamHandler(channel, tcpHandler)
                    } catch {
                        eventLoop.execute {
                            channel.close(promise: nil)
                        }
                    }
                }

                return eventLoop.makeSucceededVoidFuture()
            }
        }
    }
}

/// Channel handler that manages raw TCP communication after HTTP upgrade.
///
/// All writes to the stdin file descriptor are serialized through `writeQueue`,
/// a private serial DispatchQueue. This guarantees FIFO ordering and prevents
/// byte-interleaving between concurrent callers (channelRead on the NIO event
/// loop, setStdinWriter from a detached Swift Task).
///
/// The NSLock protects the mutable flags and stdinWriter pointer across threads.
/// The writeQueue serializes the actual fd writes independently of the lock, so
/// writes never hold the lock while potentially blocking on a full pipe.
public final class DockerTCPHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer

    let execId: String
    let ttyEnabled: Bool
    private let lock = NSLock()
    private static let logger = Logger(label: "DockerTCPHandler")
    // Serial queue — all fd writes and closes go through here.
    // Guarantees: (1) FIFO across concurrent callers, (2) no byte-interleaving
    // for writes > PIPE_BUF, (3) close always follows all pending writes.
    private let writeQueue = DispatchQueue(label: "DockerTCPHandler.stdin", qos: .userInteractive)
    private var stdinWriter: FileHandle?
    // Buffers stdin bytes arriving before setStdinWriter is called.
    // Capped at 1 MiB to prevent unbounded growth if setup is delayed.
    private var pendingData: [Data] = []
    private var pendingDataSize: Int = 0
    private static let pendingDataMaxBytes = 1 * 1024 * 1024  // 1 MiB
    private var didReceiveInputClosed = false
    private var isChannelInactive = false

    init(execId: String, ttyEnabled: Bool) {
        self.execId = execId
        self.ttyEnabled = ttyEnabled
    }

    deinit {
        // Defensive cleanup for exceptional teardown paths where channelInactive
        // never fires. deinit only runs when the stream handler Task has released
        // its reference, so writeQueue is idle — direct close is safe.
        lock.lock()
        let writer = stdinWriter
        stdinWriter = nil
        lock.unlock()
        try? writer?.close()
    }

    public func channelActive(context: ChannelHandlerContext) {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let data = buffer.getData(at: 0, length: buffer.readableBytes) else { return }
        writeToStdin(data)
    }

    /// Core write path — buffers when no writer is set yet; dispatches to
    /// writeQueue otherwise. Called by channelRead and exposed for unit tests.
    func writeToStdin(_ data: Data) {
        lock.lock()
        let writer = stdinWriter
        if writer == nil {
            if pendingDataSize + data.count <= Self.pendingDataMaxBytes {
                pendingData.append(data)
                pendingDataSize += data.count
            } else {
                Self.logger.warning(
                    "[\(execId)] stdin buffer full (\(Self.pendingDataMaxBytes) B) — discarding \(data.count) B"
                )
            }
            lock.unlock()
            return
        }
        lock.unlock()

        writeQueue.async { [execId] in
            do { try writer!.write(contentsOf: data) } catch { Self.logger.error("[\(execId)] stdin write failed: \(error)") }
        }
    }

    // Fired when Docker CLI half-closes its write side (stdin EOF).
    // Dispatching the close through writeQueue ensures it runs after all
    // previously queued writes, so the process sees EOF only after all data.
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? ChannelEvent) == .inputClosed {
            lock.lock()
            didReceiveInputClosed = true
            let writer = stdinWriter
            stdinWriter = nil
            lock.unlock()
            if let writer {
                writeQueue.async { try? writer.close() }
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        isChannelInactive = true
        let writer = stdinWriter
        stdinWriter = nil
        lock.unlock()
        if let writer {
            writeQueue.async { try? writer.close() }
        }
    }

    /// Set the stdin writer. Publishes the writer and enqueues the buffered-data
    /// flush atomically under the lock, so any concurrent writeToStdin that
    /// observes the new writer (and enqueues its write after our unlock) is
    /// guaranteed to be ordered after the flush — true FIFO preserved.
    /// writeQueue.async is non-blocking so enqueuing under the lock is safe.
    public func setStdinWriter(_ writer: FileHandle?) {
        lock.lock()
        let buffered = pendingData
        pendingData = []
        pendingDataSize = 0
        let shouldClose = didReceiveInputClosed || isChannelInactive
        if let writer {
            if !shouldClose { stdinWriter = writer }
            writeQueue.async { [execId] in
                for data in buffered {
                    do { try writer.write(contentsOf: data) } catch {
                        Self.logger.error("[\(execId)] stdin flush failed: \(error)")
                    }
                }
                if shouldClose { try? writer.close() }
            }
        }
        lock.unlock()
    }

    // MARK: - Test helpers

    /// Returns the total bytes currently buffered in pendingData.
    var pendingDataSizeForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingDataSize
    }

    /// Blocks until all pending writeQueue work completes. Call before reading
    /// pipe state in tests that write asynchronously through writeQueue.
    func drainForTesting() {
        writeQueue.sync {}
    }

    /// Simulates channelInactive without a NIO context (tests only).
    func simulateChannelInactive() {
        lock.lock()
        isChannelInactive = true
        let writer = stdinWriter
        stdinWriter = nil
        lock.unlock()
        if let writer {
            writeQueue.async { try? writer.close() }
        }
    }

    /// Simulates .inputClosed without a NIO context (tests only).
    func simulateInputClosed() {
        lock.lock()
        didReceiveInputClosed = true
        let writer = stdinWriter
        stdinWriter = nil
        lock.unlock()
        if let writer {
            writeQueue.async { try? writer.close() }
        }
    }
}

/// Helper extension to create Docker upgrader responses
extension Response {
    /// Creates a response that will upgrade to Docker TCP protocol
    static func dockerTCPUpgrade(
        execId: String,
        ttyEnabled: Bool,
        streamHandler: @escaping @Sendable (Channel, DockerTCPHandler) async throws -> Void
    ) -> Response {
        let upgrader = DockerTCPUpgrader(
            execId: execId,
            ttyEnabled: ttyEnabled,
            streamHandler: streamHandler
        )

        let response = Response(status: .switchingProtocols)
        response.upgrader = upgrader

        return response
    }
}

/// Middleware that enables HTTP connection hijacking for Docker API compatibility
/// This allows endpoints to upgrade to raw TCP for bidirectional stdin/stdout/stderr communication
public struct ConnectionHijackingMiddleware: AsyncMiddleware {

    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {

        // Only intercept specific paths that need hijacking
        guard shouldHijackConnection(for: request) else {
            return try await next.respond(to: request)
        }

        // Check if client requested connection upgrade
        let connectionHeader = request.headers.first(name: "Connection")?.lowercased()
        let upgradeHeader = request.headers.first(name: "Upgrade")?.lowercased()

        let shouldUpgrade = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp"

        let response = try await next.respond(to: request)

        // If client requested upgrade and handler returned streaming content
        if shouldUpgrade && response.status == .ok {

            // For hijacked connections, create minimal headers (no content-type for raw TCP)
            var hijackedHeaders: HTTPHeaders = [:]
            hijackedHeaders.add(name: "Connection", value: "Upgrade")
            hijackedHeaders.add(name: "Upgrade", value: "tcp")

            // Use the original response body but with HTTP 101 status
            // This should work because after 101, the body becomes raw TCP data
            let hijackedResponse = Response(
                status: .switchingProtocols,
                headers: hijackedHeaders,
                body: response.body
            )
            return hijackedResponse
        }

        // For non-upgrade requests, ensure proper content-type is set
        if response.status == .ok {
            var headers = response.headers

            // Determine content type based on TTY setting if not already set
            if headers.first(name: "Content-Type") == nil {
                let ttyEnabled = MobyBool.queryValue(request.query["tty"]) || MobyBool.queryValue(request.query["Tty"])
                let contentType = ttyEnabled ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"

                headers.replaceOrAdd(name: "Content-Type", value: contentType)
            }

            return Response(
                status: response.status,
                headers: headers,
                body: response.body
            )
        }

        return response
    }

    private func shouldHijackConnection(for request: Request) -> Bool {
        let path = request.url.path

        if path.contains("/attach") && !path.contains("/attach/ws") {
            return true
        }

        // Check for exec start endpoints
        if path.contains("/exec/") && path.hasSuffix("/start") {
            return true
        }

        return false
    }
}

/// Extension to support raw TCP hijacking for interactive sessions
/// Using NIO server implementation
extension ConnectionHijackingMiddleware {

    /// Creates a streaming response that handles Docker's TCP upgrade expectation
    static func createDockerStreamingResponse(
        request: Request,
        ttyEnabled: Bool,
        streamHandler: @escaping @Sendable (AsyncThrowingStream<ByteBuffer, Error>.Continuation) async throws -> Void
    ) -> Response {

        let connectionHeader = request.headers.first(name: "Connection")?.lowercased()
        let upgradeHeader = request.headers.first(name: "Upgrade")?.lowercased()
        let shouldUpgrade = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp"

        let contentType = ttyEnabled ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"

        var headers: HTTPHeaders = [:]
        if shouldUpgrade {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
        } else {
            headers.add(name: "Content-Type", value: contentType)
        }

        let body = Response.Body(stream: { writer in
            let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()

            Task.detached {
                do {
                    // Start the stream handler
                    try await streamHandler(continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            Task.detached {
                do {
                    for try await buffer in stream {
                        _ = writer.write(.buffer(buffer))
                    }
                    _ = writer.write(.end)
                } catch {
                    _ = writer.write(.end)
                }
            }
        })

        let status: HTTPStatus = shouldUpgrade ? .switchingProtocols : .ok
        return Response(status: status, headers: headers, body: body)
    }
}

/// Utility for creating multiplexed stream frames
public struct DockerStreamFrame {
    public enum StreamType: UInt8 {
        case stdin = 0  // Written on stdout
        case stdout = 1
        case stderr = 2
    }

    public let streamType: StreamType
    public let data: Data

    public init(streamType: StreamType, data: Data) {
        self.streamType = streamType
        self.data = data
    }
}

/// Extension to ByteBuffer for Docker stream handling
extension ByteBuffer {
    /// Writes a Docker stream frame to the buffer
    mutating func writeDockerFrame(streamType: DockerStreamFrame.StreamType, data: Data, ttyMode: Bool) {
        if ttyMode {
            // In TTY mode, data is sent raw without framing
            writeBytes(data)
        } else {
            // In non-TTY mode, use multiplexed format with 8-byte headers
            // Create 8-byte header: [stream_type, 0, 0, 0, size_big_endian]
            writeInteger(streamType.rawValue, as: UInt8.self)  // Stream type
            writeInteger(UInt8(0), as: UInt8.self)  // Padding
            writeInteger(UInt8(0), as: UInt8.self)  // Padding
            writeInteger(UInt8(0), as: UInt8.self)  // Padding
            writeInteger(UInt32(data.count), endianness: .big, as: UInt32.self)
            writeBytes(data)
        }
    }
}
