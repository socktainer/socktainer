import Darwin
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
import VaporTesting

@testable import GlassDock

@Suite("Direct TCP published-port controller")
struct DirectTCPPublishedPortControllerTests {
    @Test("writes an authorized relay header and releases the host listener")
    func relayAndUnpublish() async throws {
        try await withApp(configure: { _ in }) { app in
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("st-relay-\(UUID().uuidString.prefix(8)).sock")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let recorder = RelayHeaderRecorder()
            let relay = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(TestRelayEchoHandler(recorder: recorder))
                }
                .bind(unixDomainSocketPath: temporary.path)
                .get()
            defer { relay.close(promise: nil) }

            let reservation = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            let hostPort = try #require(reservation.localAddress?.port)
            try await reservation.close().get()

            let ready = RuntimeMachineReady(
                generation: UUID(),
                processIdentifier: 1,
                guestIPv4: "192.168.127.2",
                hostGatewayIPv4: "192.168.127.1",
                gvproxyAPI: URL(fileURLWithPath: "/tmp/unused-gvproxy.sock"),
                tcpRelaySocket: temporary
            )
            let controller = DirectTCPPublishedPortController(
                eventLoopGroup: app.eventLoopGroup,
                fallback: EmptyPublishedPortController(),
                ready: { ready }
            )
            let endpoint = PublishedPortEndpoint(
                local: "127.0.0.1:\(hostPort)",
                remote: "192.168.127.2:41000",
                protocol: .tcp
            )
            try await controller.expose(endpoint)
            #expect(try await controller.all() == Set([endpoint]))

            let descriptor = try connectTCP(port: hostPort)
            defer { Darwin.close(descriptor) }
            let payload = Array("relay-payload".utf8)
            try writeAll(payload, descriptor: descriptor)
            var response = [UInt8](repeating: 0, count: payload.count)
            let count = response.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            #expect(count == payload.count)
            #expect(response == payload)
            #expect(recorder.value() == [0x53, 0x54, 0x50, 0x46, 2, 0, 0xa0, 0x28])

            try await controller.unexpose(endpoint)
            #expect(try await controller.all().isEmpty)
            #expect(throws: (any Error).self) { try connectTCP(port: hostPort) }
        }
    }

    @Test("an unpublish during bind cannot restore a stale listener")
    func unpublishDuringBind() async throws {
        try await withApp(configure: { _ in }) { app in
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("st-relay-\(UUID().uuidString.prefix(8)).sock")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let relay = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(unixDomainSocketPath: temporary.path)
                .get()
            defer { relay.close(promise: nil) }

            let reservation = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            let hostPort = try #require(reservation.localAddress?.port)
            try await reservation.close().get()
            let endpoint = PublishedPortEndpoint(
                local: "127.0.0.1:\(hostPort)",
                remote: "192.168.127.2:41000",
                protocol: .tcp
            )
            let ready = RuntimeMachineReady(
                generation: UUID(),
                processIdentifier: 1,
                guestIPv4: "192.168.127.2",
                hostGatewayIPv4: "192.168.127.1",
                gvproxyAPI: URL(fileURLWithPath: "/tmp/unused-gvproxy.sock"),
                tcpRelaySocket: temporary
            )
            let gate = BindGate()
            let controller = DirectTCPPublishedPortController(
                eventLoopGroup: app.eventLoopGroup,
                fallback: EmptyPublishedPortController(),
                beforeBind: { await gate.pause() },
                ready: { ready }
            )

            let exposing = Task { try await controller.expose(endpoint) }
            await gate.waitUntilPaused()
            let unexposing = Task { try await controller.unexpose(endpoint) }
            await Task.yield()
            await gate.resume()
            try await exposing.value
            try await unexposing.value

            #expect(try await controller.all().isEmpty)
            #expect(throws: (any Error).self) { try connectTCP(port: hostPort) }
        }
    }

    @Test("flushes a large upload before forwarding the client half-close")
    func largeUploadHalfClose() async throws {
        try await withApp(configure: { _ in }) { app in
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("st-relay-\(UUID().uuidString.prefix(8)).sock")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let relay = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(TestRelayCollectingEchoHandler())
                }
                .bind(unixDomainSocketPath: temporary.path)
                .get()
            defer { relay.close(promise: nil) }
            let reservation = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            let hostPort = try #require(reservation.localAddress?.port)
            try await reservation.close().get()
            let ready = RuntimeMachineReady(
                generation: UUID(),
                processIdentifier: 1,
                guestIPv4: "192.168.127.2",
                hostGatewayIPv4: "192.168.127.1",
                gvproxyAPI: URL(fileURLWithPath: "/tmp/unused-gvproxy.sock"),
                tcpRelaySocket: temporary
            )
            let controller = DirectTCPPublishedPortController(
                eventLoopGroup: app.eventLoopGroup,
                fallback: EmptyPublishedPortController(),
                ready: { ready }
            )
            let endpoint = PublishedPortEndpoint(
                local: "127.0.0.1:\(hostPort)",
                remote: "192.168.127.2:41000",
                protocol: .tcp
            )
            try await controller.expose(endpoint)

            let descriptor = try connectTCP(port: hostPort)
            defer { Darwin.close(descriptor) }
            let payload = [UInt8](repeating: 0xa5, count: 8 * 1024 * 1024)
            try writeAll(payload, descriptor: descriptor)
            try #require(Darwin.shutdown(descriptor, SHUT_WR) == 0)
            var response: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count == 0 { break }
                try #require(count > 0)
                response += buffer.prefix(count)
            }
            #expect(response == payload)
            try await controller.unexpose(endpoint)
        }
    }
}

private actor BindGate {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        for waiter in pauseWaiters { waiter.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor EmptyPublishedPortController: PublishedPortControlling {
    func guestIPv4() -> String { "192.168.127.2" }
    func all() -> Set<PublishedPortEndpoint> { [] }
    func expose(_ endpoint: PublishedPortEndpoint) {}
    func unexpose(_ endpoint: PublishedPortEndpoint) {}
}

private final class RelayHeaderRecorder: @unchecked Sendable {
    private let storage = NIOLockedValueBox<[UInt8]?>(nil)
    func set(_ value: [UInt8]) { storage.withLockedValue { $0 = value } }
    func value() -> [UInt8]? { storage.withLockedValue { $0 } }
}

private final class TestRelayEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let recorder: RelayHeaderRecorder
    private var prefix: [UInt8] = []
    private var pending = ByteBuffer()
    private var frameLength: Int?

    init(recorder: RelayHeaderRecorder) { self.recorder = recorder }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if prefix.count < 8 {
            let count = min(8 - prefix.count, buffer.readableBytes)
            prefix += buffer.readBytes(length: count) ?? []
            if prefix.count == 8 { recorder.set(prefix) }
        }
        pending.writeBuffer(&buffer)
        while true {
            if frameLength == nil {
                guard let length: UInt32 = pending.readInteger(endianness: .big) else { return }
                frameLength = Int(length)
            }
            guard let frameLength, frameLength > 0,
                let payload = pending.readSlice(length: frameLength)
            else { return }
            self.frameLength = nil
            context.writeAndFlush(wrapOutboundOut(payload), promise: nil)
        }
    }
}

private final class TestRelayCollectingEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var received: [UInt8] = []
    private var headerBytesRemaining = 8
    private var pending = ByteBuffer()
    private var frameLength: Int?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if headerBytesRemaining > 0 {
            let count = min(headerBytesRemaining, buffer.readableBytes)
            buffer.moveReaderIndex(forwardBy: count)
            headerBytesRemaining -= count
        }
        pending.writeBuffer(&buffer)
        while true {
            if frameLength == nil {
                guard let length: UInt32 = pending.readInteger(endianness: .big) else { return }
                if length == 0 {
                    var response = context.channel.allocator.buffer(capacity: received.count)
                    response.writeBytes(received)
                    let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
                    context.writeAndFlush(wrapOutboundOut(response)).whenComplete { _ in
                        loopBoundContext.value.close(mode: .output, promise: nil)
                    }
                    return
                }
                frameLength = Int(length)
            }
            guard let frameLength,
                let payload = pending.readBytes(length: frameLength)
            else { return }
            self.frameLength = nil
            received += payload
        }
    }
}

private func connectTCP(port: Int) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
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
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += count
        }
    }
}
