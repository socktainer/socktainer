import Darwin
import Foundation
import Logging
import NIOCore
import NIOPosix

/// A host TCP publication connected to the persistent guest over vsock.
struct DirectTCPPortMapping: Hashable, Sendable {
    let id: String
    let hostAddress: String
    let hostPort: Int
    let guestPort: Int

    init(
        id: String,
        hostAddress: String,
        hostPort: Int,
        guestPort: Int
    ) {
        self.id = id
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

enum DirectTCPPortForwarderError: Error, Equatable {
    case duplicateIdentifier(String)
    case duplicateHostEndpoint(address: String, port: Int)
    case reconcileFailed(String, rollbackFailures: [String])
}

protocol DirectTCPListenerHandle: Sendable {
    var boundPort: Int { get }
    func close() async throws
}

protocol DirectTCPListenerFactory: Sendable {
    func start(_ mapping: DirectTCPPortMapping) async throws -> any DirectTCPListenerHandle
}

private struct NIOListenerHandle: DirectTCPListenerHandle {
    let channel: Channel

    var boundPort: Int { channel.localAddress?.port ?? 0 }

    func close() async throws {
        try await channel.close()
    }
}

protocol GuestPortConnectionDialing: Sendable {
    func dial() async throws -> FileHandle
}

struct PersistentEngineGuestPortDialer: GuestPortConnectionDialing {
    let engine: PersistentEngine

    func dial() async throws -> FileHandle {
        try await engine.dialPublishedPortProxy()
    }
}

private struct NIODirectTCPListenerFactory: DirectTCPListenerFactory {
    let eventLoopGroup: any EventLoopGroup
    let dialer: any GuestPortConnectionDialing
    let logger: Logger

    func start(_ mapping: DirectTCPPortMapping) async throws -> any DirectTCPListenerHandle {
        let host = try SocketAddress(
            ipAddress: mapping.hostAddress,
            port: mapping.hostPort
        )
        let channel = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(
                ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1
            )
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    GuestPortConnectHandler(
                        guestPort: UInt16(mapping.guestPort),
                        dialer: dialer,
                        logger: logger
                    )
                )
            }
            .bind(to: host)
            .get()
        return NIOListenerHandle(channel: channel)
    }
}

private final class GuestPortConnectHandler: ChannelInboundHandler, RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private let guestPort: UInt16
    private let dialer: any GuestPortConnectionDialing
    private let logger: Logger

    init(guestPort: UInt16, dialer: any GuestPortConnectionDialing, logger: Logger) {
        self.guestPort = guestPort
        self.dialer = dialer
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        let dialer = dialer
        let guestPort = guestPort
        context.eventLoop.makeFutureWithTask {
            let handle = try await dialer.dial()
            let descriptor = Darwin.dup(handle.fileDescriptor)
            try handle.close()
            guard descriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            return descriptor
        }.assumeIsolatedUnsafeUnchecked().flatMap { descriptor in
            ClientBootstrap(group: context.eventLoop)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .withConnectedSocket(descriptor)
        }.flatMap { peer in
            var header = peer.allocator.buffer(capacity: 7)
            header.writeBytes([0x53, 0x54, 0x50, 0x31, 0x01])
            header.writeInteger(guestPort, endianness: .big)
            return peer.writeAndFlush(header).map { peer }
        }.whenComplete { result in
            switch result {
            case .success(let peer):
                self.glue(peer, context: context)
            case .failure(let error):
                self.logger.error("guest port proxy connection failed", metadata: ["error": "\(error)"])
                context.close(promise: nil)
            }
        }
        context.fireChannelActive()
    }

    private func glue(_ peer: Channel, context: ChannelHandlerContext) {
        let (frontend, backend) = DirectTCPGlueHandler.matchedPair()
        do {
            try context.channel.pipeline.syncOperations.addHandler(frontend)
            try peer.pipeline.syncOperations.addHandler(backend)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
            try context.channel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
            try peer.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
        } catch {
            peer.close(promise: nil)
            context.close(promise: nil)
        }
    }
}

private final class DirectTCPGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: DirectTCPGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (DirectTCPGlueHandler, DirectTCPGlueHandler) {
        let first = DirectTCPGlueHandler()
        let second = DirectTCPGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
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
        if context.channel.isWritable, partner?.pendingRead == true {
            partner?.pendingRead = false
            partner?.context?.read()
        }
    }
    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable == true {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// Owns direct host listeners for the persistent engine VM.
///
/// The guest agent can call `add`, `remove`, or `reconcile` when containerd
/// emits lifecycle events. Reconciliation is idempotent. If an update fails,
/// the actor removes listeners added by that update and restores listeners it
/// removed before it reports the error.
actor DirectTCPPortForwarder {
    private struct ActivePublication {
        let mapping: DirectTCPPortMapping
        let listener: any DirectTCPListenerHandle
    }

    private struct HostEndpoint: Hashable {
        let address: String
        let port: Int
    }

    private let factory: any DirectTCPListenerFactory
    private let logger: Logger
    private var active: [String: ActivePublication] = [:]

    init(eventLoopGroup: any EventLoopGroup, engine: PersistentEngine, logger: Logger) {
        self.init(
            eventLoopGroup: eventLoopGroup,
            dialer: PersistentEngineGuestPortDialer(engine: engine),
            logger: logger
        )
    }

    init(
        eventLoopGroup: any EventLoopGroup,
        dialer: any GuestPortConnectionDialing,
        logger: Logger
    ) {
        self.factory = NIODirectTCPListenerFactory(
            eventLoopGroup: eventLoopGroup,
            dialer: dialer,
            logger: logger
        )
        self.logger = logger
    }

    init(factory: any DirectTCPListenerFactory, logger: Logger) {
        self.factory = factory
        self.logger = logger
    }

    @discardableResult
    func add(_ mapping: DirectTCPPortMapping) async throws -> DirectTCPPortMapping {
        if active[mapping.id]?.mapping == mapping {
            return mapping
        }
        var desired = active.values.map(\.mapping)
        desired.removeAll { $0.id == mapping.id }
        desired.append(mapping)
        try await reconcile(desired)
        return active[mapping.id]?.mapping ?? mapping
    }

    func remove(id: String) async throws {
        guard let publication = active.removeValue(forKey: id) else {
            return
        }
        do {
            try await publication.listener.close()
        } catch {
            active[id] = publication
            throw error
        }
    }

    func reconcile(_ mappings: [DirectTCPPortMapping]) async throws {
        let desired = try Self.validate(mappings)
        let removed = active.values
            .filter { desired[$0.mapping.id] != $0.mapping }
            .sorted { $0.mapping.id < $1.mapping.id }
        let additions = desired.values
            .filter { active[$0.id]?.mapping != $0 }
            .sorted { $0.id < $1.id }

        var removedClosed: [ActivePublication] = []
        for publication in removed {
            do {
                try await publication.listener.close()
                active.removeValue(forKey: publication.mapping.id)
                removedClosed.append(publication)
            } catch {
                let rollbackFailures = await restore(removedClosed)
                throw DirectTCPPortForwarderError.reconcileFailed(
                    String(describing: error),
                    rollbackFailures: rollbackFailures
                )
            }
        }

        var added: [ActivePublication] = []
        do {
            for mapping in additions {
                let listener = try await factory.start(mapping)
                let realized = DirectTCPPortMapping(
                    id: mapping.id,
                    hostAddress: mapping.hostAddress,
                    hostPort: listener.boundPort,
                    guestPort: mapping.guestPort
                )
                let publication = ActivePublication(mapping: realized, listener: listener)
                active[mapping.id] = publication
                added.append(publication)
            }
        } catch {
            var rollbackFailures: [String] = []
            for publication in added.reversed() {
                do {
                    try await publication.listener.close()
                    active.removeValue(forKey: publication.mapping.id)
                } catch {
                    rollbackFailures.append(String(describing: error))
                }
            }
            rollbackFailures.append(contentsOf: await restore(removedClosed))
            logger.error(
                "Direct TCP publication reconciliation failed",
                metadata: ["error": "\(error)", "rollbackFailures": "\(rollbackFailures)"]
            )
            throw DirectTCPPortForwarderError.reconcileFailed(
                String(describing: error),
                rollbackFailures: rollbackFailures
            )
        }
    }

    func shutdown() async {
        let publications = active.values.sorted { $0.mapping.id < $1.mapping.id }
        active.removeAll()
        for publication in publications {
            do {
                try await publication.listener.close()
            } catch {
                logger.warning(
                    "Failed to close direct TCP publication",
                    metadata: ["id": "\(publication.mapping.id)", "error": "\(error)"]
                )
            }
        }
    }

    func mappings() -> [DirectTCPPortMapping] {
        active.values.map(\.mapping).sorted { $0.id < $1.id }
    }

    private func restore(_ publications: [ActivePublication]) async -> [String] {
        var failures: [String] = []
        for publication in publications {
            do {
                let listener = try await factory.start(publication.mapping)
                let restored = ActivePublication(
                    mapping: DirectTCPPortMapping(
                        id: publication.mapping.id,
                        hostAddress: publication.mapping.hostAddress,
                        hostPort: listener.boundPort,
                        guestPort: publication.mapping.guestPort
                    ),
                    listener: listener
                )
                active[publication.mapping.id] = restored
            } catch {
                failures.append(String(describing: error))
            }
        }
        return failures
    }

    private static func validate(
        _ mappings: [DirectTCPPortMapping]
    ) throws -> [String: DirectTCPPortMapping] {
        var desired: [String: DirectTCPPortMapping] = [:]
        var endpoints: [HostEndpoint: String] = [:]
        for mapping in mappings {
            guard desired[mapping.id] == nil else {
                throw DirectTCPPortForwarderError.duplicateIdentifier(mapping.id)
            }
            let endpoint = HostEndpoint(
                address: mapping.hostAddress,
                port: mapping.hostPort
            )
            if endpoints[endpoint] != nil {
                throw DirectTCPPortForwarderError.duplicateHostEndpoint(
                    address: endpoint.address,
                    port: endpoint.port
                )
            }
            desired[mapping.id] = mapping
            endpoints[endpoint] = mapping.id
        }
        return desired
    }
}
