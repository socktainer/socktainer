import Darwin
import NIOCore
import NIOPosix
import Testing
import VaporTesting

@testable import GlassDock

@Suite("Docker API gateway")
struct DockerAPIGatewayTests {
    @Test("serves only a close-delimited ping on the fast path")
    func fastPing() async throws {
        try await withGateway { gateway, _, publicPath, recorder in
            let get = try exchange(
                path: publicPath,
                request: "GET /v1.51/_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
            )
            #expect(get.contains("Api-Version: 9.87"))
            #expect(get.contains("Builder-Version: gateway-test"))
            #expect(get.contains("Docker-Experimental: true"))
            #expect(get.hasSuffix("\r\n\r\nOK"))

            let head = try exchange(
                path: publicPath,
                request: "HEAD /_ping HTTP/1.0\r\nConnection: close\r\n\r\n"
            )
            #expect(head.contains("Content-Length: 0"))
            #expect(head.hasSuffix("\r\n\r\n"))
            #expect(recorder.snapshot().isEmpty)
            withExtendedLifetime(gateway) {}
        }
    }

    @Test(
        "proxies unsafe ping forms and preserves all received bytes",
        arguments: [
            "GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: keep-alive\r\n\r\n",
            "GET /_ping HTTP/1.1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
            "HEAD /_ping HTTP/1.1\r\nConnection: close\r\nExpect: 100-continue\r\n\r\n",
            "POST /_ping HTTP/1.1\r\nConnection: close\r\nContent-Length: 4\r\n\r\ndata",
            "GET /version HTTP/1.1\r\nConnection: close\r\n\r\n",
            "GET /_ping HTTP/1.1\r\nConnection: close\r\n\r\n",
            "GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close, Upgrade\r\nUpgrade: tcp\r\n\r\n",
        ])
    func fallback(request: String) async throws {
        try await withGateway { gateway, _, publicPath, recorder in
            let response = try exchange(path: publicPath, request: request)
            let responseBytes = Array(response.utf8)
            let requestBytes = Array(request.utf8)
            #expect(responseBytes.count == requestBytes.count)
            let difference = zip(responseBytes, requestBytes).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            #expect(difference == nil)
            #expect(recorder.snapshot() == [Array(request.utf8)])
            withExtendedLifetime(gateway) {}
        }
    }

    @Test("proxies data larger than each bounded flow-control buffer")
    func largeProxy() async throws {
        try await withGateway { gateway, _, publicPath, recorder in
            let body = String(repeating: "0123456789abcdef", count: 16_384)
            let request =
                "POST /containers/create HTTP/1.1\r\nHost: docker\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            let response = try exchange(path: publicPath, request: request)
            let responseBytes = Array(response.utf8)
            let requestBytes = Array(request.utf8)
            #expect(responseBytes.count == requestBytes.count)
            let difference = zip(responseBytes, requestBytes).enumerated().first {
                $0.element.0 != $0.element.1
            }?.offset
            #expect(difference == nil)
            #expect(recorder.snapshot() == [Array(request.utf8)])
            withExtendedLifetime(gateway) {}
        }
    }

    @Test("stops active proxy connections and removes the public socket")
    func stop() async throws {
        let directory = URL(
            fileURLWithPath: "/tmp/stgw-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backendPath = directory.appendingPathComponent("backend.sock").path
        let publicPath = directory.appendingPathComponent("public.sock").path

        try await withApp(configure: { _ in }) { app in
            let backend = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(unixDomainSocketPath: backendPath)
                .get()
            defer { backend.close(promise: nil) }
            let gateway = try DockerAPIGateway(
                configuration: .init(
                    publicSocketPath: publicPath,
                    backendSocketPath: backendPath,
                    apiVersion: "1.51"
                )
            )
            let descriptor = try connectUnix(path: publicPath)
            gateway.stop()
            var byte: UInt8 = 0
            #expect(Darwin.read(descriptor, &byte, 1) == 0)
            Darwin.close(descriptor)
            #expect(!FileManager.default.fileExists(atPath: publicPath))
        }
    }

    @Test("does not remove a socket path that it did not bind")
    func startFailurePreservesPath() throws {
        let path = "/tmp/stgw-\(UUID().uuidString.prefix(8)).sock"
        try Data("owner".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: DockerAPIGatewayError.self) {
            _ = try DockerAPIGateway(
                configuration: .init(
                    publicSocketPath: path,
                    backendSocketPath: path,
                    apiVersion: "1.51"
                )
            )
        }
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

private final class GatewayRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [[UInt8]] = []

    func append(_ request: [UInt8]) {
        lock.withLock { requests.append(request) }
    }

    func snapshot() -> [[UInt8]] {
        lock.withLock { requests }
    }
}

private final class GatewayEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let recorder: GatewayRequestRecorder
    private var received: [UInt8] = []

    init(recorder: GatewayRequestRecorder) {
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received += buffer.readBytes(length: buffer.readableBytes) ?? []
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            recorder.append(received)
            var response = context.channel.allocator.buffer(capacity: received.count)
            response.writeBytes(received)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(response)).flatMap {
                channel.close(mode: .output)
            }.whenFailure { _ in
                channel.close(promise: nil)
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private func withGateway(
    _ body: (
        DockerAPIGateway,
        String,
        String,
        GatewayRequestRecorder
    ) async throws -> Void
) async throws {
    let directory = URL(
        fileURLWithPath: "/tmp/stgw-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backendPath = directory.appendingPathComponent("backend.sock").path
    let publicPath = directory.appendingPathComponent("public.sock").path
    let recorder = GatewayRequestRecorder()
    try await withApp(configure: { _ in }) { app in
        let backend = try await ServerBootstrap(group: app.eventLoopGroup)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(GatewayEchoHandler(recorder: recorder))
            }
            .bind(unixDomainSocketPath: backendPath)
            .get()
        defer { backend.close(promise: nil) }
        let gateway = try DockerAPIGateway(
            configuration: .init(
                publicSocketPath: publicPath,
                backendSocketPath: backendPath,
                apiVersion: "9.87",
                builderVersion: "gateway-test",
                experimental: true
            )
        )
        defer { gateway.stop() }
        try await body(gateway, backendPath, publicPath, recorder)
    }
}

private func exchange(path: String, request: String) throws -> String {
    let descriptor = try connectUnix(path: path)
    defer { Darwin.close(descriptor) }
    try writeAll(Array(request.utf8), descriptor: descriptor)
    guard shutdown(descriptor, SHUT_WR) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var response: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        if count == 0 { break }
        guard count > 0 else {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        response += buffer.prefix(count)
    }
    return String(decoding: response, as: UTF8.self)
}

private func connectUnix(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let copied = path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: 104) {
                strlcpy($0, source, 104)
            }
        }
    }
    guard copied < 104 else {
        Darwin.close(descriptor)
        throw POSIXError(.ENAMETOOLONG)
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}

private func writeAll(_ bytes: [UInt8], descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
    }
}
