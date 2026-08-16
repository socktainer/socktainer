import Darwin
import Foundation
import NIOCore
import NIOPosix

/// Publishes TCP ports through a direct host-listener-to-vsock relay while UDP
/// remains on gvproxy. The guest authorizes each relay header against its live
/// publication registry before it dials a container address.
actor DirectTCPPublishedPortController: PublishedPortControlling {
    typealias ReadyProvider = @Sendable () async throws -> RuntimeMachineReady
    typealias BeforeBind = @Sendable () async -> Void

    private let fallback: any PublishedPortControlling
    private let ready: ReadyProvider
    private let eventLoopGroup: any EventLoopGroup
    private let beforeBind: BeforeBind
    private var generation: UUID?
    private var listeners: [PublishedPortEndpoint: DirectTCPListenerState] = [:]

    init(
        eventLoopGroup: any EventLoopGroup,
        ready: @escaping ReadyProvider
    ) {
        self.fallback = GVProxyPublishedPortController(ready: ready)
        self.ready = ready
        self.eventLoopGroup = eventLoopGroup
        self.beforeBind = {}
    }

    init(
        eventLoopGroup: any EventLoopGroup,
        fallback: any PublishedPortControlling,
        beforeBind: @escaping BeforeBind = {},
        ready: @escaping ReadyProvider
    ) {
        self.fallback = fallback
        self.ready = ready
        self.eventLoopGroup = eventLoopGroup
        self.beforeBind = beforeBind
    }

    func guestIPv4() async throws -> String {
        try await ready().guestIPv4
    }

    func all() async throws -> Set<PublishedPortEndpoint> {
        let snapshot = try await ready()
        try await synchronize(with: snapshot)
        let fallbackEndpoints = try await fallback.all()
        return fallbackEndpoints.union(listeners.keys)
    }

    func expose(_ endpoint: PublishedPortEndpoint) async throws {
        guard endpoint.protocol == .tcp else {
            try await fallback.expose(endpoint)
            return
        }
        let snapshot = try await ready()
        try await synchronize(with: snapshot)
        if listeners[endpoint] != nil { return }
        let guestPort = try Self.port(from: endpoint.remote)
        let (host, hostPort) = try Self.hostAndPort(from: endpoint.local)
        let relayAddress = try SocketAddress(unixDomainSocketPath: snapshot.tcpRelaySocket.path)
        let state = DirectTCPListenerState()
        listeners[endpoint] = state
        await beforeBind()
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(
                ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)),
                value: 1
            )
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                guard state.add(channel) else { return channel.close() }
                channel.closeFuture.whenComplete { _ in state.remove(channel) }
                return channel.pipeline.addHandler(
                    DirectTCPConnectHandler(relayAddress: relayAddress, guestPort: guestPort)
                )
            }
        do {
            let channel = try await bootstrap.bind(host: host, port: hostPort).get()
            state.completeBind(channel)
            guard listeners[endpoint] === state, generation == snapshot.generation else {
                try await state.close()
                return
            }
        } catch {
            state.completeBind(nil)
            if listeners[endpoint] === state {
                listeners.removeValue(forKey: endpoint)
            }
            try? await state.close()
            if let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE {
                throw GuestPortPublicationError.gvproxy(
                    status: 409,
                    message: "address already in use: \(endpoint.local)"
                )
            }
            throw error
        }
    }

    func unexpose(_ endpoint: PublishedPortEndpoint) async throws {
        guard endpoint.protocol == .tcp else {
            try await fallback.unexpose(endpoint)
            return
        }
        guard let state = listeners[endpoint] else { return }
        try await state.close()
        if listeners[endpoint] === state {
            listeners.removeValue(forKey: endpoint)
        }
    }

    private func synchronize(with snapshot: RuntimeMachineReady) async throws {
        guard generation != snapshot.generation else { return }
        let previous = listeners.values
        listeners.removeAll()
        generation = snapshot.generation
        for state in previous { try? await state.close() }
    }

    private static func port(from endpoint: String) throws -> Int {
        guard let text = endpoint.split(separator: ":").last,
            let port = Int(text),
            (1...65_535).contains(port)
        else {
            throw GuestPortPublicationError.invalidGVProxyResponse(
                "invalid relay endpoint: \(endpoint)"
            )
        }
        return port
    }

    private static func hostAndPort(from endpoint: String) throws -> (String, Int) {
        guard let separator = endpoint.lastIndex(of: ":") else {
            throw GuestPortPublicationError.invalidGVProxyResponse(
                "invalid host endpoint: \(endpoint)"
            )
        }
        var host = String(endpoint[..<separator])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty,
            let port = Int(endpoint[endpoint.index(after: separator)...]),
            (1...65_535).contains(port)
        else {
            throw GuestPortPublicationError.invalidGVProxyResponse(
                "invalid host endpoint: \(endpoint)"
            )
        }
        return (host, port)
    }
}

private final class DirectTCPListenerState: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Channel?
    private var children: [ObjectIdentifier: Channel] = [:]
    private var closing = false
    private var bindCompleted = false
    private var bindWaiters: [CheckedContinuation<Void, Never>] = []

    func completeBind(_ channel: Channel?) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            listener = channel
            bindCompleted = true
            let result = bindWaiters
            bindWaiters.removeAll()
            return result
        }
        for waiter in waiters { waiter.resume() }
    }

    func add(_ channel: Channel) -> Bool {
        lock.withLock {
            guard !closing else { return false }
            children[ObjectIdentifier(channel)] = channel
            return true
        }
    }

    func remove(_ channel: Channel) {
        _ = lock.withLock { children.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    func close() async throws {
        let mustWait = lock.withLock {
            closing = true
            return !bindCompleted
        }
        if mustWait {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if bindCompleted { return true }
                    bindWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let channels: [Channel] = lock.withLock {
            let result = [listener].compactMap { $0 } + children.values
            listener = nil
            children.removeAll()
            return Array(result)
        }
        for channel in channels where channel.isActive {
            try? await channel.close().get()
        }
    }
}

private final class DirectTCPConnectHandler: ChannelInboundHandler, RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private let relayAddress: SocketAddress
    private let guestPort: Int

    init(relayAddress: SocketAddress, guestPort: Int) {
        self.relayAddress = relayAddress
        self.guestPort = guestPort
    }

    func channelActive(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(2))
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.autoRead, value: false)
            .connect(to: relayAddress)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                switch result {
                case .success(let relay):
                    guard loopBoundContext.value.channel.isActive else {
                        relay.close(promise: nil)
                        return
                    }
                    var header = relay.allocator.buffer(capacity: 8)
                    header.writeBytes([0x53, 0x54, 0x50, 0x46, 2, 0])
                    header.writeInteger(UInt16(self.guestPort), endianness: .big)
                    relay.writeAndFlush(header).flatMap {
                        self.glue(relay, context: loopBoundContext.value)
                    }.whenFailure { _ in
                        relay.close(promise: nil)
                        loopBoundContext.value.close(promise: nil)
                    }
                case .failure(let error):
                    loopBoundContext.value.fireErrorCaught(error)
                    loopBoundContext.value.close(promise: nil)
                }
            }
        context.fireChannelActive()
    }

    private func glue(_ relay: Channel, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let (clientGlue, relayGlue) = DirectTCPGlueHandler.matchedPair()
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        return context.pipeline.addHandler(clientGlue).flatMap {
            relay.pipeline.addHandler(relayGlue)
        }.flatMap {
            loopBoundContext.value.pipeline.removeHandler(self)
        }.flatMap {
            loopBoundContext.value.channel.eventLoop.execute {
                loopBoundContext.value.channel.read()
            }
            return loopBoundContext.value.channel.eventLoop.makeSucceededVoidFuture()
        }.flatMap {
            relay.eventLoop.execute { relay.read() }
            return relay.eventLoop.makeSucceededVoidFuture()
        }
    }
}

private final class DirectTCPGlueHandler: @unchecked Sendable {
    private var partner: DirectTCPGlueHandler?
    private let contextLock = NSLock()
    private var contextBox: NIOLoopBoundBox<ChannelHandlerContext?>?
    private var lastWrite: EventLoopFuture<Void>?
    private let frameInbound: Bool
    private var forwardedEOF = false
    private var inboundBytes = 0

    private init(frameInbound: Bool) { self.frameInbound = frameInbound }

    static func matchedPair() -> (DirectTCPGlueHandler, DirectTCPGlueHandler) {
        let first = DirectTCPGlueHandler(frameInbound: true)
        let second = DirectTCPGlueHandler(frameInbound: false)
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: ByteBuffer, framed: Bool) {
        onEventLoop { context in
            var payload = data
            var frame = payload
            if framed {
                frame = context.channel.allocator.buffer(capacity: 4 + payload.readableBytes)
                frame.writeInteger(UInt32(payload.readableBytes), endianness: .big)
                frame.writeBuffer(&payload)
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            self.lastWrite = promise.futureResult
            context.writeAndFlush(self.wrapOutboundOut(frame), promise: promise)
            promise.futureResult.whenComplete { result in
                if case .failure = result {
                    self.partner?.partnerClose()
                } else {
                    self.partner?.partnerWriteCompleted()
                }
            }
        }
    }
    private func partnerFlush() { onEventLoop { $0.flush() } }
    private func partnerWriteFrameEOF(totalBytes: Int) {
        onEventLoop { context in
            var frame = context.channel.allocator.buffer(capacity: 12)
            frame.writeInteger(UInt32(0), endianness: .big)
            frame.writeInteger(UInt64(totalBytes), endianness: .big)
            context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
        }
    }

    private func partnerWriteCompleted() { onEventLoop { $0.read() } }

    private func partnerWriteEOF() {
        onEventLoop { context in
            let loopBoundContext = context.loopBound
            context.flush()
            (self.lastWrite ?? context.eventLoop.makeSucceededVoidFuture()).whenComplete {
                result in
                switch result {
                case .success:
                    self.closeOutputWhenDrained(
                        context: loopBoundContext.value,
                        deadline: .now() + .seconds(5)
                    )
                case .failure:
                    loopBoundContext.value.close(promise: nil)
                }
            }
        }
    }

    private func closeOutputWhenDrained(
        context: ChannelHandlerContext,
        deadline: NIODeadline
    ) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.getOption(
            ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_NWRITE))
        ).whenComplete { result in
            switch result {
            case .success(0):
                loopBoundContext.value.close(mode: .output, promise: nil)
            case .success where .now() < deadline:
                loopBoundContext.value.eventLoop.scheduleTask(in: .milliseconds(1)) {
                    self.closeOutputWhenDrained(
                        context: loopBoundContext.value,
                        deadline: deadline
                    )
                }
            case .success, .failure:
                loopBoundContext.value.close(mode: .output, promise: nil)
            }
        }
    }
    private func partnerClose() { onEventLoop { $0.close(promise: nil) } }

    private func onEventLoop(_ body: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        let box = contextLock.withLock { contextBox }
        guard let box else { return }
        box.eventLoop.execute {
            guard let context = box.value else { return }
            body(context)
        }
    }

}

extension DirectTCPGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func handlerAdded(context: ChannelHandlerContext) {
        contextLock.withLock {
            contextBox = NIOLoopBoundBox(context, eventLoop: context.eventLoop)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        contextLock.withLock { contextBox = nil }
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        inboundBytes += buffer.readableBytes
        partner?.partnerWrite(buffer, framed: frameInbound)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if frameInbound, !forwardedEOF {
            forwardedEOF = true
            partner?.partnerWriteFrameEOF(totalBytes: inboundBytes)
        }
        if !frameInbound { partner?.partnerClose() }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            guard !forwardedEOF else { return }
            forwardedEOF = true
            if frameInbound {
                partner?.partnerWriteFrameEOF(totalBytes: inboundBytes)
            } else {
                partner?.partnerWriteEOF()
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerClose()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        context.read()
    }

}
