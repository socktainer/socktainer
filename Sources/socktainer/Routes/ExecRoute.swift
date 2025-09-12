import Foundation
import NIO
import NIOHTTP1
import NIOCore
import Containerization
import ContainerizationExtras
import ContainerizationOS
import TerminalProgress
// -------------------------------------------------
// ExecManager (actor) - stores exec configs + pty fd
// -------------------------------------------------
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

    struct ExecRecord {
        var config: ExecConfig
        var ptyFD: Int32?
    }

    private var storage: [String: ExecRecord] = [:]

    func create(config: ExecConfig) -> String {
        let id = UUID().uuidString
        storage[id] = ExecRecord(config: config, ptyFD: nil)
        print("[ExecManager] Stored exec config \(id): cmd=\(config.cmd), tty=\(config.tty)")
        return id
    }

    func getConfig(id: String) -> ExecConfig? {
        guard let record = storage[id] else {
            print("[ExecManager] Exec config \(id) not found")
            return nil
        }
        return record.config
    }

    func remove(id: String) {
        storage.removeValue(forKey: id)
    }

    func setPTYFD(id: String, fd: Int32?) {
        guard var record = storage[id] else { return }
        record.ptyFD = fd
        storage[id] = record
    }

    func getPTYFD(id: String) -> Int32? {
        return storage[id]?.ptyFD
    }
}

// -------------------------------------------------
// ExecStreamHandler - forwards process IO to channel
// -------------------------------------------------
final class ExecStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let stdin: FileHandle?
    private let stdout: FileHandle?
    private let stderr: FileHandle?
    private let tty: Bool
    private let execId: String

    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private weak var ctx: ChannelHandlerContext?

    private var pendingStdout = Data()
    private var pendingStderr = Data()
    private var upgraded = false

    init(stdin: FileHandle?, stdout: FileHandle?, stderr: FileHandle?, tty: Bool, execId: String) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.tty = tty
        self.execId = execId
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.ctx = context
    }

func channelActive(context: ChannelHandlerContext) {
    self.ctx = context
    setupForwarding(stdout: stdout, streamID: 1)
    if !tty {
        setupForwarding(stdout: stderr, streamID: 2)
    }
}


    func markUpgraded() {
        guard let ctx = ctx else { return }
        upgraded = true

        if !pendingStdout.isEmpty {
            flush(data: pendingStdout, streamID: 1, ctx: ctx)
            pendingStdout.removeAll()
        }
        if !pendingStderr.isEmpty && !tty {
            flush(data: pendingStderr, streamID: 2, ctx: ctx)
            pendingStderr.removeAll()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        stdoutSource?.cancel()
        stderrSource?.cancel()
        stdoutSource = nil
        stderrSource = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let d = buffer.readData(length: buffer.readableBytes) ?? Data()
        if !d.isEmpty {
            try? self.stdin?.write(contentsOf: d)
        }
    }

private func setupForwarding(stdout: FileHandle?, streamID: UInt8) {
    guard let stdout = stdout, let ctx = ctx else { return }
    let fd = stdout.fileDescriptor
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())

src.setEventHandler {
    let data = stdout.availableData
    print("[ExecStreamHandler] read \(data.count) bytes from fd=\(fd), upgraded=\(self.upgraded)")
    guard !data.isEmpty else {
        print("[ExecStreamHandler] EOF/no data")
        return
    }
    if !self.upgraded {
        print("[ExecStreamHandler] buffering \(data.count) bytes")
        self.pendingStdout.append(data)
    } else {
        print("[ExecStreamHandler] flushing \(data.count) bytes immediately")
        self.flush(data: data, streamID: streamID, ctx: ctx)
    }
}

    src.setCancelHandler { close(fd) }
    src.resume()

    if streamID == 1 {
        stdoutSource = src
    } else {
        stderrSource = src
    }
}

func flushPending(ctx: ChannelHandlerContext) {
    if !pendingStdout.isEmpty {
        print("[ExecStreamHandler] flushing pending stdout \(pendingStdout.count) bytes")
        flush(data: pendingStdout, streamID: 1, ctx: ctx)
        pendingStdout.removeAll()
    }
    if !pendingStderr.isEmpty && !tty {
        print("[ExecStreamHandler] flushing pending stderr \(pendingStderr.count) bytes")
        flush(data: pendingStderr, streamID: 2, ctx: ctx)
        pendingStderr.removeAll()
    }
    upgraded = true
}

private func flush(data: Data, streamID: UInt8, ctx: ChannelHandlerContext) {
    print("[ExecStreamHandler] sending \(data.count) bytes")
    var buffer = ctx.channel.allocator.buffer(capacity: data.count + 8)
    if tty {
        buffer.writeBytes(data)
    } else {
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = streamID
        let len = UInt32(data.count).bigEndian
        header[4] = UInt8((len >> 24) & 0xff)
        header[5] = UInt8((len >> 16) & 0xff)
        header[6] = UInt8((len >> 8)  & 0xff)
        header[7] = UInt8(len & 0xff)
        print("[ExecStreamHandler] header: \(header.map { String(format: "%02x", $0) }.joined(separator: " "))")
        buffer.writeBytes(header)
        buffer.writeBytes(data)
    }
    ctx.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
    print("[ExecStreamHandler] sent \(data.count) bytes")
}




}




// -------------------------------------------------
// Helper: PTY resize (no-op for now)
// -------------------------------------------------
fileprivate func resizePTY(fd: Int32, width: Int32, height: Int32) throws {
    // No-op; placeholder
}

// -------------------------------------------------
// Error type
// -------------------------------------------------
enum ExecRouteError: Error {
    case missingExecID
    case execNotFound
}

// -------------------------------------------------
// DTOs
// -------------------------------------------------
struct ExecCreateRequest: Codable {
    let Cmd: [String]
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let Tty: Bool?
    let Detach: Bool?
}

struct StartExecRequest: Codable {
    let Detach: Bool?
    let Tty: Bool?
}

// -------------------------------------------------
// Routes
// -------------------------------------------------
struct ExecCreateRoute: HTTPRoute {
    let methods: [HTTPMethod] = [.POST]
    let paths: [String] = ["/:version/containers/:id/exec", "/containers/:id/exec"]

    func handle(requestHead: HTTPRequestHead, channel: Channel, client: any ClientProtocol, body: Data?) async throws {
                print("[ExecCreateRoute] init...")

        guard let body = body else {
            print("[ExecCreateRoute] No body received")
            return
        }
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .useDefaultKeys
              
        do {
            let req = try jsonDecoder.decode(ExecCreateRequest.self, from: body)
            print("[ExecCreateRoute] Decoded request: \(req)")
                print("[ExecCreateRoute] init2...")

                // container id is computed from path, it's the last path before /exec (start from the end)
                let containerId = requestHead.uri.split(separator: "/")
                    .reversed()
                    .dropFirst() // drop "exec"
                    .first.map(String.init) ?? ""
                    print("container id is \(containerId)")
        let config = ExecManager.ExecConfig(
            containerId: containerId,
            cmd: req.Cmd,
            attachStdin: req.AttachStdin ?? false,
            attachStdout: req.AttachStdout ?? false,
            attachStderr: req.AttachStderr ?? false,
            tty: req.Tty ?? false,
            detach: req.Detach ?? false
        )
        print("[ExecCreateRoute] Creating exec for container \(containerId) with cmd: \(req.Cmd), tty: \(req.Tty), attachStdin: \(req.AttachStdin), attachStdout: \(req.AttachStdout), attachStderr: \(req.AttachStderr), detach: \(req.Detach)")
        let id = await ExecManager.shared.create(config: config)
        let resp = ["Id": id]
        let jsonData = try JSONSerialization.data(withJSONObject: resp, options: [])
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(jsonData.count)")
        headers.add(name: "Content-Type", value: "application/json")
        print("headers are \(headers)")
        let responseHead = HTTPResponseHead(version: requestHead.version, status: .created, headers: headers)
        channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
        var buffer = channel.allocator.buffer(capacity: jsonData.count)
        buffer.writeBytes(jsonData)
        print("writing data \(String(data: jsonData, encoding: .utf8) ?? "")")
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)

        } catch {
            // Detailed error logging
            if let jsonStr = String(data: body, encoding: .utf8) {
                print("[ExecCreateRoute] Failed to decode JSON: \(jsonStr)")
            }
            print("[ExecCreateRoute] Decoding error: \(error)")
        }

    }
}

struct ExecGetRoute: HTTPRoute {
    let methods: [HTTPMethod] = [.GET]
    let paths: [String] = ["/:version/exec/:id/json", "/exec/:id/json"]

    func handle(requestHead: HTTPRequestHead, channel: Channel, client: any ClientProtocol, body: Data?) async throws {
        let pathComponents = requestHead.uri.split(separator: "/")
        guard let idIndex = pathComponents.firstIndex(where: { $0 == "exec" })?.advanced(by: 1),
              pathComponents.count > idIndex else { throw ExecRouteError.missingExecID }
        let execId = String(pathComponents[idIndex])
        guard let config = await ExecManager.shared.getConfig(id: execId) else { throw ExecRouteError.execNotFound }
        let responseDict: [String: Any] = [
            "ID": execId,
            "Running": false,
            "ExitCode": NSNull(),
            "ProcessConfig": [
                "tty": config.tty,
                "entrypoint": config.cmd.first ?? "",
                "arguments": Array(config.cmd.dropFirst())
            ],
            "OpenStdin": config.attachStdin,
            "OpenStdout": config.attachStdout,
            "OpenStderr": config.attachStderr,
            "ContainerID": config.containerId
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: responseDict, options: [])
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(jsonData.count)")
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        let responseHead = HTTPResponseHead(version: requestHead.version, status: .ok, headers: headers)
        channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
        var buffer = channel.allocator.buffer(capacity: jsonData.count)
        buffer.writeBytes(jsonData)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
}

struct ExecStartRoute: HTTPRoute {
    let methods: [HTTPMethod] = [.POST]
    let paths: [String] = ["/:version/exec/:id/start", "/exec/:id/start"]

    func handle(requestHead: HTTPRequestHead, channel: Channel, client: any ClientProtocol, body: Data?) async throws {
        let pathComponents = requestHead.uri.split(separator: "/")
        guard let idIndex = pathComponents.firstIndex(where: { $0 == "exec" })?.advanced(by: 1),
              pathComponents.count > idIndex else { throw ExecRouteError.missingExecID }

        let execId: String = String(pathComponents[idIndex])
        guard let config = await ExecManager.shared.getConfig(id: execId) else { throw ExecRouteError.execNotFound }

        // Create ProcessIO
        let io = try ProcessIO.create(tty: config.tty, interactive: config.attachStdin, detach: config.detach)

        // Fetch container
        guard let container = try await client.getContainer(id: config.containerId) else { throw ExecRouteError.execNotFound }

        var processConfig = container.configuration.initProcess
        processConfig.executable = config.cmd.first!
        processConfig.arguments = Array(config.cmd.dropFirst())
        processConfig.terminal = config.tty

        // Create process
        let process = try await container.createProcess(
            id: UUID().uuidString.lowercased(),
            configuration: processConfig,
            stdio: io.stdio
        )

        // Attach server-side logging (optional)
        // if let stdoutHandle = io.stdout?.fileHandleForReading {
        //     stdoutHandle.readabilityHandler = { handle in
        //         let data = handle.availableData
        //         if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
        //             print("[Exec \(execId)] stdout: \(str)")
        //         }
        //     }
        // }
        // if let stderrHandle = io.stderr?.fileHandleForReading {
        //     stderrHandle.readabilityHandler = { handle in
        //         let data = handle.availableData
        //         if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
        //             print("[Exec \(execId)] stderr: \(str)")
        //         }
        //     }
        // }

        // ---- Handle Docker TCP Upgrade ----
        let isUpgrade = requestHead.headers.contains(name: "Upgrade") && requestHead.headers.first(name: "Upgrade") == "tcp"
// Debug: print pipeline handler names
var names = [String]()
var iterator = channel.pipeline.makeIterator()
while let entry = iterator.next() {
    names.append(entry.name)
}
print("[ExecStartRoute] pipeline before upgrade: \(names)")


        if isUpgrade {
            // Send 101 Switching Protocols
            var headers = HTTPHeaders()
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
            let responseHead = HTTPResponseHead(version: requestHead.version, status: .switchingProtocols, headers: headers)
            channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)

            // Attach ExecStreamHandler to forward process IO
            let execHandler = ExecStreamHandler(
    stdin: io.stdin?.fileHandleForWriting,
    stdout: io.stdout?.fileHandleForReading,
    stderr: io.stderr?.fileHandleForReading,
    tty: config.tty,
    execId: execId
)

channel.pipeline.addHandler(execHandler, name: "ExecStreamHandler", position: .last).whenComplete { addResult in
    switch addResult {
    case .failure(let err):
        print("[ExecStartRoute] Failed to add ExecStreamHandler: \(err)")
    case .success:
        channel.pipeline.context(name: "ExecStreamHandler").whenComplete { ctxResult in
            switch ctxResult {
            case .failure(let ctxErr):
                print("[ExecStartRoute] Failed to fetch ExecStreamHandler context: \(ctxErr)")
            case .success(let ctx):
                print("[ExecStartRoute] Exec \(execId) stream handler attached (Upgrade TCP) — flushing pending")
                execHandler.flushPending(ctx: ctx)
            }
        }
    }
}
            
        } else {
            // Non-upgrade HTTP case (detach)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            let responseHead = HTTPResponseHead(version: requestHead.version, status: .ok, headers: headers)
            channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        }

        // Start the process
        try await process.start()

        if config.detach {
            try io.closeAfterStart()
            await ExecManager.shared.setPTYFD(id: execId, fd: nil)
        } else {
            // Wait for process completion in background
            Task {
                try await process.wait()
                try await io.wait()
                await ExecManager.shared.remove(id: execId)
            }
        }
    }
}






struct ExecResizeRoute: HTTPRoute {
    let methods: [HTTPMethod] = [.POST]
    let paths: [String] = ["/exec/:id/resize"]

    func handle(requestHead: HTTPRequestHead, channel: Channel, client: any ClientProtocol, body: Data?) async throws {
        // no-op
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        let responseHead = HTTPResponseHead(version: requestHead.version, status: .ok, headers: headers)
        channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
        let buffer = channel.allocator.buffer(string: "{\"resized\":true}")
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
}


struct OSFile: Sendable {
    private let fd: Int32

    enum IOAction: Equatable {
        case eof
        case again
        case success
        case brokenPipe
        case error(_ errno: Int32)
    }

    init(fd: Int32) {
        self.fd = fd
    }

    init(handle: FileHandle) {
        self.fd = handle.fileDescriptor
    }

    func makeNonBlocking() throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1 else {
            throw POSIXError.fromErrno()
        }

        if fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1 {
            throw POSIXError.fromErrno()
        }
    }

    func write(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (wrote: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesWrote: Int = 0
        while true {
            let n = Darwin.write(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesWrote),
                buffer.count - bytesWrote
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesWrote, .again)
                }
                return (bytesWrote, .error(errno))
            }

            if n == 0 {
                return (bytesWrote, .brokenPipe)
            }

            bytesWrote += n
            if bytesWrote < buffer.count {
                continue
            }
            return (bytesWrote, .success)
        }
    }

    func read(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (read: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesRead: Int = 0
        while true {
            let n = Darwin.read(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesRead),
                buffer.count - bytesRead
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesRead, .again)
                }
                return (bytesRead, .error(errno))
            }

            if n == 0 {
                return (bytesRead, .eof)
            }

            bytesRead += n
            if bytesRead < buffer.count {
                continue
            }
            return (bytesRead, .success)
        }
    }
}

struct ProcessIO {
    let stdin: Pipe?
    let stdout: Pipe?
    let stderr: Pipe?
    var ioTracker: IoTracker?

    struct IoTracker {
        let stream: AsyncStream<Void>
        let cont: AsyncStream<Void>.Continuation
        let configuredStreams: Int
    }

    let stdio: [FileHandle?]

    let console: Terminal?

    func closeAfterStart() throws {
        try stdin?.fileHandleForReading.close()
        try stdout?.fileHandleForWriting.close()
        try stderr?.fileHandleForWriting.close()
    }

    func close() throws {
        try console?.reset()
    }

    static func create(tty: Bool, interactive: Bool, detach: Bool) throws -> ProcessIO {
        let current: Terminal? = try {
            if !tty || !interactive {
                return nil
            }
            let current = try Terminal.current
            try current.setraw()
            return current
        }()

        var stdio = [FileHandle?](repeating: nil, count: 3)

        let stdin: Pipe? = {
            if !interactive {
                return nil
            }
            return Pipe()
        }()

        if let stdin {
            let pin = FileHandle.standardInput
            let stdinOSFile = OSFile(fd: pin.fileDescriptor)
            let pipeOSFile = OSFile(fd: stdin.fileHandleForWriting.fileDescriptor)
            try stdinOSFile.makeNonBlocking()
            nonisolated(unsafe) let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))

            pin.readabilityHandler = { _ in
                Self.streamStdin(
                    from: stdinOSFile,
                    to: pipeOSFile,
                    buffer: buf,
                ) {
                    pin.readabilityHandler = nil
                    buf.deallocate()
                    try? stdin.fileHandleForWriting.close()
                }
            }
            stdio[0] = stdin.fileHandleForReading
        }

        let stdout: Pipe? = {
            if detach {
                return nil
            }
            return Pipe()
        }()

        var configuredStreams = 0
        let (stream, cc) = AsyncStream<Void>.makeStream()
        if let stdout {
            configuredStreams += 1
            let pout: FileHandle = {
                if let current {
                    return current.handle
                }
                return .standardOutput
            }()

            let rout = stdout.fileHandleForReading
            rout.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rout.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! pout.write(contentsOf: data)
            }
            stdio[1] = stdout.fileHandleForWriting
        }

        let stderr: Pipe? = {
            if detach || tty {
                return nil
            }
            return Pipe()
        }()
        if let stderr {
            configuredStreams += 1
            let perr: FileHandle = .standardError
            let rerr = stderr.fileHandleForReading
            rerr.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rerr.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! perr.write(contentsOf: data)
            }
            stdio[2] = stderr.fileHandleForWriting
        }

        var ioTracker: IoTracker? = nil
        if configuredStreams > 0 {
            ioTracker = .init(stream: stream, cont: cc, configuredStreams: configuredStreams)
        }

        return .init(
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            ioTracker: ioTracker,
            stdio: stdio,
            console: current
        )
    }

    static func streamStdin(
        from: OSFile,
        to: OSFile,
        buffer: UnsafeMutableBufferPointer<UInt8>,
        onErrorOrEOF: () -> Void,
    ) {
        while true {
            let (bytesRead, action) = from.read(buffer)
            if bytesRead > 0 {
                let view = UnsafeMutableBufferPointer(
                    start: buffer.baseAddress,
                    count: bytesRead
                )

                let (bytesWritten, _) = to.write(view)
                if bytesWritten != bytesRead {
                    onErrorOrEOF()
                    return
                }
            }

            switch action {
            case .error(_), .eof, .brokenPipe:
                onErrorOrEOF()
                return
            case .again:
                return
            case .success:
                break
            }
        }
    }

    public func wait() async throws {
        guard let ioTracker = self.ioTracker else {
            return
        }
        do {
            try await Timeout.run(seconds: 10) {
                var counter = ioTracker.configuredStreams
                for await _ in ioTracker.stream {
                    counter -= 1
                    if counter == 0 {
                        ioTracker.cont.finish()
                        break
                    }
                }
            }
        } catch {
            print("Timeout waiting for IO to complete : \(error)")
            throw error
        }
    }
}