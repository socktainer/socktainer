import Foundation
import NIOCore
import NIOHTTP1
import Vapor

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

        return context.pipeline.addHandler(tcpHandler).flatMap { _ in
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

/// Channel handler that manages raw TCP communication after HTTP upgrade
public final class DockerTCPHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer

    let execId: String
    let ttyEnabled: Bool
    private var stdinWriter: FileHandle?

    init(execId: String, ttyEnabled: Bool) {
        self.execId = execId
        self.ttyEnabled = ttyEnabled
    }

    public func channelActive(context: ChannelHandlerContext) {
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)

        // Handle raw TCP input from client (stdin)
        // This data should be forwarded to the process stdin
        if let stdinWriter = self.stdinWriter {
            if let data = buffer.getData(at: 0, length: buffer.readableBytes) {
                do {
                    try stdinWriter.write(contentsOf: data)

                    // Force flush the data to ensure it reaches the process
                    try stdinWriter.synchronize()
                } catch {
                    // Failed to write to stdin
                }
            } else {
                // No buffer data available
            }
        } else {
            // No stdin writer available
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        try? stdinWriter?.close()
    }

    // Method to set the stdin writer from the stream handler
    public func setStdinWriter(_ writer: FileHandle?) {
        self.stdinWriter = writer
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
                let ttyEnabled = request.query["tty"] == "true" || request.query["Tty"] == "true"
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

    /// Creates the 8-byte header for multiplexed streams
    public func createHeader() -> Data {
        var header = Data(capacity: 8)
        header.append(streamType.rawValue)  // Stream type
        header.append(0)  // Padding
        header.append(0)  // Padding
        header.append(0)  // Padding

        // Append size as big-endian uint32
        let size = UInt32(data.count)
        let sizeBytes = withUnsafeBytes(of: size.bigEndian) { Data($0) }
        header.append(sizeBytes)

        return header
    }

    /// Creates the complete frame (header + data) for multiplexed streams
    public func createFrame() -> Data {
        var frame = createHeader()
        frame.append(data)
        return frame
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
            let frame = DockerStreamFrame(streamType: streamType, data: data)
            writeBytes(frame.createFrame())
        }
    }
}
