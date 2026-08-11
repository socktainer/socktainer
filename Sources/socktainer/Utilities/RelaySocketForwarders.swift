import Logging
import NIOCore
import NIOPosix
import SocketForwarder

/// Localhost listeners whose backend is an Apple `publishedSockets` Unix socket.
/// No host-side connection is made to a guest-network IP.
struct RelayTCPForwarder: SocketForwarder {
    let proxyAddress: SocketAddress
    let relaySocketPath: String
    let destination: PortRelayProtocol.Destination
    let eventLoopGroup: any EventLoopGroup
    let log: Logger?

    func run() throws -> EventLoopFuture<SocketForwarderResult> {
        ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(
                ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)),
                value: 1
            )
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        RelayTCPConnectHandler(
                            relaySocketPath: relaySocketPath,
                            destination: destination,
                            log: log
                        )
                    )
                }
            }
            .bind(to: proxyAddress)
            .map { SocketForwarderResult(channel: $0) }
    }
}

private final class RelayTCPConnectHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let relaySocketPath: String
    private let destination: PortRelayProtocol.Destination
    private var log: Logger?

    init(
        relaySocketPath: String,
        destination: PortRelayProtocol.Destination,
        log: Logger?
    ) {
        self.relaySocketPath = relaySocketPath
        self.destination = destination
        self.log = log
    }

    func channelActive(context: ChannelHandlerContext) {
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(unixDomainSocketPath: relaySocketPath)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                switch result {
                case .success(let backend):
                    self.activate(backend: backend, frontend: context)
                case .failure(let error):
                    self.log?.error("relay backend connect failed: \(error)")
                    context.fireErrorCaught(error)
                    context.close(promise: nil)
                }
            }
        context.fireChannelActive()
    }

    private func activate(backend: any Channel, frontend: ChannelHandlerContext) {
        let frontendChannel = frontend.channel
        guard frontendChannel.isActive else {
            backend.close(promise: nil)
            return
        }
        do {
            var preface = backend.allocator.buffer(capacity: PortRelayProtocol.prefaceLength)
            try destination.writePreface(into: &preface)
            try backend.pipeline.syncOperations.addHandler(
                RelayAcknowledgementHandler { [weak self] status in
                    guard let self else { return }
                    self.finishActivation(
                        status: status,
                        backend: backend,
                        frontend: frontend
                    )
                }
            )
            backend.writeAndFlush(preface).whenComplete { result in
                switch result {
                case .success:
                    try? backend.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
                case .failure(let error):
                    self.log?.error("relay preface write failed: \(error)")
                    backend.close(promise: nil)
                    frontendChannel.close(promise: nil)
                }
            }
        } catch {
            backend.close(promise: nil)
            frontend.close(promise: nil)
        }
    }

    private func finishActivation(
        status: Result<PortRelayProtocol.ConnectStatus, Error>,
        backend: any Channel,
        frontend: ChannelHandlerContext
    ) {
        let frontendChannel = frontend.channel
        guard frontendChannel.isActive, backend.isActive else {
            backend.close(promise: nil)
            frontend.close(promise: nil)
            return
        }
        do {
            let connectStatus = try status.get()
            guard connectStatus == .ready else {
                log?.warning("relay target connect failed with status \(connectStatus)")
                backend.close(promise: nil)
                frontend.close(promise: nil)
                return
            }
            let (frontendGlue, backendGlue) = RelayGlueHandler.matchedPair()
            try frontendChannel.pipeline.syncOperations.addHandler(frontendGlue)
            try backend.pipeline.syncOperations.addHandler(backendGlue)
            frontendChannel.pipeline.syncOperations.removeHandler(self, promise: nil)
            try? frontendChannel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
            try? backend.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
        } catch {
            log?.error("invalid relay acknowledgement: \(error)")
            backend.close(promise: nil)
            frontend.close(promise: nil)
        }
    }
}

private final class RelayAcknowledgementHandler: ChannelInboundHandler, RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let completion: (Result<PortRelayProtocol.ConnectStatus, Error>) -> Void
    private var buffered = ByteBuffer()
    private var completed = false

    init(completion: @escaping (Result<PortRelayProtocol.ConnectStatus, Error>) -> Void) {
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        var incoming = unwrapInboundIn(data)
        buffered.writeBuffer(&incoming)
        do {
            guard let status = try PortRelayProtocol.readAcknowledgement(from: &buffered) else {
                return
            }
            completed = true
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
            completion(.success(status))
            if buffered.readableBytes > 0 {
                context.fireChannelRead(wrapInboundOut(buffered))
            }
        } catch {
            completed = true
            completion(.failure(error))
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        completion(.failure(ChannelError.eof))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        completion(.failure(error))
        context.close(promise: nil)
    }
}

private final class RelayGlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: RelayGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (RelayGlueHandler, RelayGlueHandler) {
        let first = RelayGlueHandler()
        let second = RelayGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.context?.write(data, promise: nil) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.context?.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.context?.close(promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.context?.close(mode: .output, promise: nil)
        }
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        guard context.channel.isWritable, partner?.pendingRead == true else { return }
        partner?.pendingRead = false
        partner?.context?.read()
    }
    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable == true {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

struct RelayUDPForwarder: SocketForwarder {
    let proxyAddress: SocketAddress
    let relaySocketPath: String
    let destination: PortRelayProtocol.Destination
    let eventLoopGroup: any EventLoopGroup
    let log: Logger?

    func run() throws -> EventLoopFuture<SocketForwarderResult> {
        DatagramBootstrap(group: eventLoopGroup)
            .channelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        RelayUDPFrontend(
                            relaySocketPath: relaySocketPath,
                            destination: destination,
                            log: log
                        )
                    )
                }
            }
            .bind(to: proxyAddress)
            .map { SocketForwarderResult(channel: $0) }
    }
}

private final class RelayUDPFrontend: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private static let maximumSessions = 256
    private let relaySocketPath: String
    private let destination: PortRelayProtocol.Destination
    private let log: Logger?
    private var sessions: [SocketAddress: RelayUDPSession] = [:]
    private var insertionOrder: [SocketAddress] = []

    init(relaySocketPath: String, destination: PortRelayProtocol.Destination, log: Logger?) {
        self.relaySocketPath = relaySocketPath
        self.destination = destination
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        if let session = sessions[envelope.remoteAddress] {
            session.send(envelope.data)
            return
        }
        if sessions.count >= Self.maximumSessions, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            sessions.removeValue(forKey: oldest)?.close()
        }
        let client = envelope.remoteAddress
        let session = RelayUDPSession(
            clientAddress: client,
            frontend: context.channel,
            relaySocketPath: relaySocketPath,
            destination: destination,
            log: log,
            onClose: { [weak self] in
                self?.sessions.removeValue(forKey: client)
                self?.insertionOrder.removeAll { $0 == client }
            }
        )
        sessions[client] = session
        insertionOrder.append(client)
        session.send(envelope.data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let openSessions = Array(sessions.values)
        sessions.removeAll()
        insertionOrder.removeAll()
        for session in openSessions { session.close() }
    }
}

private final class RelayUDPSession: @unchecked Sendable {
    private static let maximumQueuedDatagrams = 8
    private static let idleTimeout = TimeAmount.seconds(60)
    private let clientAddress: SocketAddress
    private let frontend: any Channel
    private let relaySocketPath: String
    private let destination: PortRelayProtocol.Destination
    private let log: Logger?
    private let onClose: () -> Void
    private var backend: (any Channel)?
    private var queued: [ByteBuffer] = []
    private var connecting = false
    private var closed = false
    private var idleTask: Scheduled<Void>?

    init(
        clientAddress: SocketAddress,
        frontend: any Channel,
        relaySocketPath: String,
        destination: PortRelayProtocol.Destination,
        log: Logger?,
        onClose: @escaping () -> Void
    ) {
        self.clientAddress = clientAddress
        self.frontend = frontend
        self.relaySocketPath = relaySocketPath
        self.destination = destination
        self.log = log
        self.onClose = onClose
    }

    func send(_ payload: ByteBuffer) {
        guard !closed else { return }
        refreshIdleTimeout()
        if let backend {
            write(payload, to: backend)
            return
        }
        guard queued.count < Self.maximumQueuedDatagrams else { return }
        queued.append(payload)
        guard !connecting else { return }
        connecting = true
        ClientBootstrap(group: frontend.eventLoop)
            .channelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        RelayUDPResponseDecoder(
                            clientAddress: self.clientAddress,
                            frontend: self.frontend,
                            onActivity: { [weak self] in self?.refreshIdleTimeout() },
                            onClose: { [weak self] in self?.close() }
                        )
                    )
                }
            }
            .connect(unixDomainSocketPath: relaySocketPath)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                self.connecting = false
                switch result {
                case .success(let channel):
                    guard !self.closed, self.frontend.isActive else {
                        channel.close(promise: nil)
                        self.queued.removeAll()
                        return
                    }
                    self.backend = channel
                    var preface = channel.allocator.buffer(capacity: PortRelayProtocol.prefaceLength)
                    do {
                        try self.destination.writePreface(into: &preface)
                        channel.writeAndFlush(preface, promise: nil)
                        let pending = self.queued
                        self.queued.removeAll(keepingCapacity: true)
                        for payload in pending { self.write(payload, to: channel) }
                    } catch {
                        channel.close(promise: nil)
                    }
                case .failure(let error):
                    guard !self.closed else { return }
                    self.log?.error("UDP relay backend connect failed: \(error)")
                    self.queued.removeAll()
                    self.close()
                }
            }
    }

    private func write(_ payload: ByteBuffer, to channel: any Channel) {
        // UDP provides no delivery guarantee. Dropping while the bounded NIO
        // outbound buffer is applying backpressure is preferable to allowing
        // an unbounded queue to grow behind a slow relay.
        guard channel.isWritable else { return }
        do {
            var frame = channel.allocator.buffer(capacity: payload.readableBytes + 2)
            try PortRelayProtocol.writeDatagram(payload, into: &frame)
            channel.writeAndFlush(frame, promise: nil)
        } catch {
            log?.warning("dropping oversized UDP relay datagram: \(error)")
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleTask?.cancel()
        idleTask = nil
        queued.removeAll()
        backend?.close(promise: nil)
        backend = nil
        onClose()
    }

    private func refreshIdleTimeout() {
        guard !closed else { return }
        idleTask?.cancel()
        idleTask = frontend.eventLoop.scheduleTask(in: Self.idleTimeout) { [weak self] in
            self?.close()
        }
    }
}

private final class RelayUDPResponseDecoder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let clientAddress: SocketAddress
    private let frontend: any Channel
    private let onActivity: () -> Void
    private let onClose: () -> Void
    private var buffered = ByteBuffer()
    private var acknowledged = false

    init(
        clientAddress: SocketAddress,
        frontend: any Channel,
        onActivity: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.clientAddress = clientAddress
        self.frontend = frontend
        self.onActivity = onActivity
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffered.writeBuffer(&incoming)
        if !acknowledged {
            do {
                guard let status = try PortRelayProtocol.readAcknowledgement(from: &buffered) else {
                    return
                }
                guard status == .ready else {
                    context.close(promise: nil)
                    return
                }
                acknowledged = true
            } catch {
                context.close(promise: nil)
                return
            }
        }
        while let length: UInt16 = buffered.getInteger(at: buffered.readerIndex, endianness: .big) {
            let count = Int(length)
            guard count <= PortRelayProtocol.maximumDatagramLength else {
                context.close(promise: nil)
                return
            }
            guard buffered.readableBytes >= count + 2 else { return }
            buffered.moveReaderIndex(forwardBy: 2)
            guard let payload = buffered.readSlice(length: count) else { return }
            onActivity()
            if frontend.isWritable {
                frontend.writeAndFlush(
                    AddressedEnvelope(remoteAddress: clientAddress, data: payload),
                    promise: nil
                )
            }
        }
        buffered.discardReadBytes()
    }

    func channelInactive(context: ChannelHandlerContext) { onClose() }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

enum RelayRouteProbe {
    static func status(
        socketPath: String,
        destination: PortRelayProtocol.Destination,
        eventLoopGroup: any EventLoopGroup
    ) async throws -> PortRelayProtocol.ConnectStatus {
        let eventLoop = eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: PortRelayProtocol.ConnectStatus.self)
        let channel = try await ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(1))
            .channelInitializer { channel in
                channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    channel.pipeline.addHandler(
                        RelayProbeHandler(destination: destination, promise: promise)
                    )
                }
            }
            .connect(unixDomainSocketPath: socketPath)
            .get()
        defer { channel.close(promise: nil) }
        return try await promise.futureResult.get()
    }
}

private final class RelayProbeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let destination: PortRelayProtocol.Destination
    private let promise: EventLoopPromise<PortRelayProtocol.ConnectStatus>
    private var buffered = ByteBuffer()
    private var completed = false
    private var timeout: Scheduled<Void>?
    private weak var handlerContext: ChannelHandlerContext?

    init(
        destination: PortRelayProtocol.Destination,
        promise: EventLoopPromise<PortRelayProtocol.ConnectStatus>
    ) {
        self.destination = destination
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        handlerContext = context
        do {
            var preface = context.channel.allocator.buffer(
                capacity: PortRelayProtocol.prefaceLength
            )
            try destination.writePreface(into: &preface)
            context.writeAndFlush(NIOAny(preface), promise: nil)
            try? context.channel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
            timeout = context.eventLoop.scheduleTask(in: .seconds(6)) { [weak self] in
                self?.probeTimedOut()
            }
        } catch {
            finish(.failure(error), context: context)
        }
        context.fireChannelActive()
    }

    private func probeTimedOut() {
        guard let handlerContext else { return }
        finish(
            .failure(ChannelError.connectTimeout(.seconds(6))),
            context: handlerContext
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffered.writeBuffer(&incoming)
        do {
            guard let status = try PortRelayProtocol.readAcknowledgement(from: &buffered) else {
                return
            }
            finish(.success(status), context: context)
        } catch {
            finish(.failure(error), context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(ChannelError.eof), context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error), context: context)
    }

    private func finish(
        _ value: Result<PortRelayProtocol.ConnectStatus, Error>,
        context: ChannelHandlerContext
    ) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        timeout = nil
        promise.completeWith(value)
        context.close(promise: nil)
    }
}
