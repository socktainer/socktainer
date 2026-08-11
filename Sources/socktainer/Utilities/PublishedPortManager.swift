import ContainerResource
import ContainerizationExtras
import Darwin
import Foundation
import Logging
import NIO
import SocketForwarder
import Vapor

protocol NetworkPortRelayProviding: Sendable {
    /// Ensures the network-scoped guest relay is running and returns the local
    /// Unix socket transported by Apple Container over vsock.
    func ensureRelay(
        networkID: String,
        checking destination: PortRelayProtocol.Destination
    ) async throws -> String
}

/// Owns Docker's localhost listeners while delegating the guest-network hop to a
/// network-scoped relay reached through Apple Container's published Unix socket.
/// This avoids a direct LaunchAgent-to-guest IP connection, which macOS Local
/// Network Privacy can deny even when the same binary works from Terminal.
actor PublishedPortManager {
    enum PortError: Error {
        case missingContainerAddress(String)
    }

    private let eventLoopGroup: any EventLoopGroup
    private let logger: Logger
    private let relayProvider: (any NetworkPortRelayProviding)?
    private var active: [String: ActivePublication] = [:]
    private var operationLocks: [String: OperationLockEntry] = [:]
    private var pendingReservations: [UUID: [Int32]] = [:]
    private var heldReservations: [String: [Int32]] = [:]
    private var handoffReservations: [PortKey: Int] = [:]

    private struct PortKey: Hashable {
        let address: String
        let port: UInt16
        let transport: ForwarderSpecification.Transport
    }

    struct DynamicPortReservation: Sendable {
        fileprivate let id: UUID
        let ports: [PublishPort]
    }

    private struct ActivePublication {
        let specifications: [ForwarderSpecification]
        let forwarders: [SocketForwarderResult]
    }

    private struct OperationLockEntry {
        let lock: AsyncLock
        var users: Int
    }

    struct ForwarderSpecification: Equatable, Sendable {
        enum Transport: String, Sendable {
            case tcp
            case udp
        }

        let hostAddress: String
        let hostPort: Int
        let containerAddress: String
        let containerPort: Int
        let transport: Transport

        static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.hostAddress != rhs.hostAddress { return lhs.hostAddress < rhs.hostAddress }
            if lhs.hostPort != rhs.hostPort { return lhs.hostPort < rhs.hostPort }
            if lhs.containerAddress != rhs.containerAddress { return lhs.containerAddress < rhs.containerAddress }
            if lhs.containerPort != rhs.containerPort { return lhs.containerPort < rhs.containerPort }
            return lhs.transport.rawValue < rhs.transport.rawValue
        }
    }

    init(
        eventLoopGroup: any EventLoopGroup,
        logger: Logger,
        relayProvider: (any NetworkPortRelayProviding)? = nil
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.relayProvider = relayProvider
    }

    func reserveDynamicPorts(_ ports: [PublishPort]) throws -> DynamicPortReservation {
        let id = UUID()
        var descriptors: [Int32] = []
        var resolved: [PublishPort] = []
        do {
            for mapping in ports {
                guard mapping.hostPort == 0 else {
                    resolved.append(mapping)
                    continue
                }
                let reserved = try reserveDynamicRange(
                    address: mapping.hostAddress.description,
                    transport: mapping.proto == .tcp ? .tcp : .udp,
                    count: Int(mapping.count)
                )
                descriptors.append(contentsOf: reserved.descriptors)
                resolved.append(
                    try PublishPort(
                        hostAddress: mapping.hostAddress,
                        hostPort: reserved.basePort,
                        containerPort: mapping.containerPort,
                        proto: mapping.proto,
                        count: mapping.count
                    )
                )
            }
        } catch {
            for descriptor in descriptors { _ = Darwin.close(descriptor) }
            throw error
        }
        pendingReservations[id] = descriptors
        return DynamicPortReservation(id: id, ports: resolved)
    }

    func commit(_ reservation: DynamicPortReservation, nativeID: String) {
        guard let descriptors = pendingReservations.removeValue(forKey: reservation.id) else {
            return
        }
        if let old = heldReservations.removeValue(forKey: nativeID) {
            for descriptor in old { _ = Darwin.close(descriptor) }
        }
        heldReservations[nativeID] = descriptors
    }

    func cancel(_ reservation: DynamicPortReservation) {
        guard let descriptors = pendingReservations.removeValue(forKey: reservation.id) else {
            return
        }
        for descriptor in descriptors { _ = Darwin.close(descriptor) }
    }

    func reconcile(container: ContainerSnapshot) async throws {
        let lock = retainOperationLock(for: container.id)
        do {
            try await lock.withLock { _ in
                try await self.reconcileLocked(container: container)
            }
            releaseOperationLock(for: container.id, lock: lock)
        } catch {
            releaseOperationLock(for: container.id, lock: lock)
            throw error
        }
    }

    /// The actor alone is not a sufficient critical section: starting and
    /// stopping a SocketForwarder suspends, which permits another actor call to
    /// enter. Keep the complete per-container transaction under an async lock so
    /// recovery polling and lifecycle routes cannot both bind (or close past) the
    /// same publication.
    private func reconcileLocked(container: ContainerSnapshot) async throws {
        let ports = await DockerContainerMetadataStore.shared.ports(
            nativeID: container.id,
            fallback: container.configuration.publishedPorts
        )
        guard !ports.isEmpty else {
            await closeLocked(nativeID: container.id)
            return
        }
        guard let endpoint = Self.publicationEndpoint(in: container) else {
            throw PortError.missingContainerAddress(container.id)
        }
        let address = endpoint.address
        let specifications = Self.specifications(for: ports, containerAddress: address)
        // Always revalidate the relay, even when the frontend specification did
        // not change. The sidecar/runtime can disappear independently during an
        // Apple system restart while this in-memory listener remains active.
        let relayDestination = try PortRelayProtocol.Destination(
            address: specifications[0].containerAddress,
            port: specifications[0].containerPort,
            transport: specifications[0].transport == .tcp ? .tcp : .udp
        )
        let relaySocketPath = try await relayProvider?.ensureRelay(
            networkID: endpoint.network,
            checking: relayDestination
        )
        if active[container.id]?.specifications == specifications {
            logger.debug("Published ports for \(container.id) are already reconciled")
            return
        }

        let handoffKeys = Set(
            specifications.map {
                PortKey(
                    address: $0.hostAddress,
                    port: UInt16($0.hostPort),
                    transport: $0.transport
                )
            })
        for key in handoffKeys {
            handoffReservations[key, default: 0] += 1
        }
        defer {
            for key in handoffKeys {
                let remaining = (handoffReservations[key] ?? 1) - 1
                if remaining == 0 {
                    handoffReservations.removeValue(forKey: key)
                } else {
                    handoffReservations[key] = remaining
                }
            }
        }

        if let descriptors = heldReservations.removeValue(forKey: container.id) {
            for descriptor in descriptors { _ = Darwin.close(descriptor) }
        }

        if let previous = active.removeValue(forKey: container.id) {
            await closeAndWait(previous.forwarders, nativeID: container.id)
        }

        var started: [SocketForwarderResult] = []
        do {
            for specification in specifications {
                let host = try SocketAddress(
                    ipAddress: specification.hostAddress,
                    port: specification.hostPort
                )
                let backend = try SocketAddress(
                    ipAddress: specification.containerAddress,
                    port: specification.containerPort
                )
                var result: SocketForwarderResult?
                var lastError: Error?
                for attempt in 0..<3 {
                    do {
                        switch (specification.transport, relaySocketPath) {
                        case (.tcp, .some(let socketPath)):
                            result = try await RelayTCPForwarder(
                                proxyAddress: host,
                                relaySocketPath: socketPath,
                                destination: try PortRelayProtocol.Destination(
                                    address: specification.containerAddress,
                                    port: specification.containerPort,
                                    transport: .tcp
                                ),
                                eventLoopGroup: eventLoopGroup,
                                log: logger
                            ).run().get()
                        case (.udp, .some(let socketPath)):
                            result = try await RelayUDPForwarder(
                                proxyAddress: host,
                                relaySocketPath: socketPath,
                                destination: try PortRelayProtocol.Destination(
                                    address: specification.containerAddress,
                                    port: specification.containerPort,
                                    transport: .udp
                                ),
                                eventLoopGroup: eventLoopGroup,
                                log: logger
                            ).run().get()
                        case (.tcp, .none):
                            result = try await TCPForwarder(
                                proxyAddress: host,
                                serverAddress: backend,
                                eventLoopGroup: eventLoopGroup,
                                log: logger
                            ).run().get()
                        case (.udp, .none):
                            result = try await UDPForwarder(
                                proxyAddress: host,
                                serverAddress: backend,
                                eventLoopGroup: eventLoopGroup,
                                log: logger
                            ).run().get()
                        }
                        break
                    } catch {
                        lastError = error
                        if attempt < 2 {
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                    }
                }
                guard let result else { throw lastError ?? PortError.missingContainerAddress(container.id) }
                started.append(result)
            }
            active[container.id] = ActivePublication(
                specifications: specifications,
                forwarders: started
            )
            logger.notice("reconciled \(started.count) published port(s) for \(container.id) at \(address)")
        } catch {
            await closeAndWait(started, nativeID: container.id)
            throw error
        }
    }

    func close(nativeID: String) async {
        let lock = retainOperationLock(for: nativeID)
        await lock.withLock { _ in
            await self.closeLocked(nativeID: nativeID)
        }
        releaseOperationLock(for: nativeID, lock: lock)
    }

    private func closeLocked(nativeID: String) async {
        if let descriptors = heldReservations.removeValue(forKey: nativeID) {
            for descriptor in descriptors { _ = Darwin.close(descriptor) }
        }
        guard let publication = active.removeValue(forKey: nativeID) else { return }
        await closeAndWait(publication.forwarders, nativeID: nativeID)
    }

    func shutdown() async {
        for id in Array(active.keys) { await close(nativeID: id) }
        for descriptors in pendingReservations.values {
            for descriptor in descriptors { _ = Darwin.close(descriptor) }
        }
        for descriptors in heldReservations.values {
            for descriptor in descriptors { _ = Darwin.close(descriptor) }
        }
        pendingReservations.removeAll()
        heldReservations.removeAll()
    }

    private func retainOperationLock(for nativeID: String) -> AsyncLock {
        if var entry = operationLocks[nativeID] {
            entry.users += 1
            operationLocks[nativeID] = entry
            return entry.lock
        }
        let lock = AsyncLock(log: logger)
        operationLocks[nativeID] = OperationLockEntry(lock: lock, users: 1)
        return lock
    }

    private func releaseOperationLock(for nativeID: String, lock: AsyncLock) {
        guard var entry = operationLocks[nativeID], entry.lock === lock else { return }
        precondition(entry.users > 0, "published-port operation lock released without a user")
        entry.users -= 1
        if entry.users == 0 {
            operationLocks.removeValue(forKey: nativeID)
        } else {
            operationLocks[nativeID] = entry
        }
    }

    func cachedOperationLockCount() -> Int { operationLocks.count }

    static func publicationAddress(in container: ContainerSnapshot) -> String? {
        publicationEndpoint(in: container)?.address
    }

    static func publicationEndpoint(
        in container: ContainerSnapshot
    ) -> (network: String, address: String)? {
        let reserved: Set<String> = ["default", "bridge", "host", "none"]
        if let named = container.networks.first(where: {
            let address = $0.ipv4Address.address.description
            return !$0.network.isEmpty && !reserved.contains($0.network)
                && !address.isEmpty && address != "0.0.0.0"
        }) {
            return (named.network, named.ipv4Address.address.description)
        }
        // Unlike embedded DNS, host publication is valid on Docker's reserved
        // default/bridge networks. Only host/none lack a guest endpoint.
        let unusable: Set<String> = ["host", "none"]
        return container.networks.first {
            let address = $0.ipv4Address.address.description
            return !unusable.contains($0.network)
                && !address.isEmpty && address != "0.0.0.0"
        }.map { ($0.network, $0.ipv4Address.address.description) }
    }

    static func specifications(
        for ports: [PublishPort],
        containerAddress: String
    ) -> [ForwarderSpecification] {
        ports.flatMap { mapping in
            (0..<mapping.count).map { offset in
                ForwarderSpecification(
                    hostAddress: mapping.hostAddress.description,
                    hostPort: Int(mapping.hostPort + offset),
                    containerAddress: containerAddress,
                    containerPort: Int(mapping.containerPort + offset),
                    transport: mapping.proto == .tcp ? .tcp : .udp
                )
            }
        }.sorted(by: ForwarderSpecification.ordered)
    }

    private func reserveDynamicRange(
        address: String,
        transport: ForwarderSpecification.Transport,
        count: Int
    ) throws -> (descriptors: [Int32], basePort: UInt16) {
        let count = max(1, count)
        for _ in 0..<128 {
            var descriptors: [Int32] = []
            do {
                let first = try Self.reserveSocket(
                    address: address,
                    port: 0,
                    transport: transport
                )
                descriptors.append(first.fd)
                guard Int(first.port) + count - 1 <= Int(UInt16.max) else {
                    throw POSIXError(.EADDRINUSE)
                }
                let keys = (0..<count).map {
                    PortKey(
                        address: address,
                        port: first.port + UInt16($0),
                        transport: transport
                    )
                }
                guard keys.allSatisfy({ handoffReservations[$0] == nil }) else {
                    throw POSIXError(.EADDRINUSE)
                }
                for offset in 1..<count {
                    let next = try Self.reserveSocket(
                        address: address,
                        port: first.port + UInt16(offset),
                        transport: transport
                    )
                    descriptors.append(next.fd)
                }
                return (descriptors, first.port)
            } catch {
                for descriptor in descriptors { _ = Darwin.close(descriptor) }
            }
        }
        throw POSIXError(.EADDRINUSE)
    }

    private static func reserveSocket(
        address: String,
        port: UInt16,
        transport: ForwarderSpecification.Transport
    ) throws -> (fd: Int32, port: UInt16) {
        let family = address.contains(":") ? AF_INET6 : AF_INET
        let socketType = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        let socketProtocol = transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP
        let fd = Darwin.socket(family, socketType, socketProtocol)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            if family == AF_INET6 {
                var value = sockaddr_in6()
                value.sin6_family = sa_family_t(AF_INET6)
                value.sin6_port = port.bigEndian
                guard inet_pton(AF_INET6, address, &value.sin6_addr) == 1 else {
                    throw POSIXError(.EINVAL)
                }
                let bound = withUnsafePointer(to: &value) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                guard bound == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                var actual = sockaddr_in6()
                var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let found = withUnsafeMutablePointer(to: &actual) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.getsockname(fd, $0, &length)
                    }
                }
                guard found == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                return (fd, UInt16(bigEndian: actual.sin6_port))
            }

            var value = sockaddr_in()
            value.sin_family = sa_family_t(AF_INET)
            value.sin_port = port.bigEndian
            guard inet_pton(AF_INET, address, &value.sin_addr) == 1 else {
                throw POSIXError(.EINVAL)
            }
            let bound = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &length)
                }
            }
            guard found == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return (fd, UInt16(bigEndian: actual.sin_port))
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private func closeAndWait(
        _ forwarders: [SocketForwarderResult],
        nativeID: String
    ) async {
        for forwarder in forwarders { forwarder.close() }
        for forwarder in forwarders {
            do {
                try await forwarder.wait()
            } catch {
                logger.warning("Failed while closing a published port for \(nativeID): \(error)")
            }
        }
    }
}

struct PublishedPortManagerKey: Vapor.StorageKey {
    typealias Value = PublishedPortManager
}

struct PublishedPortManagerLifecycle: LifecycleHandler {
    let manager: PublishedPortManager

    func shutdownAsync(_ application: Application) async {
        await manager.shutdown()
        await PublishedPortManagerRegistry.shared.clear(manager)
    }
}

actor PublishedPortManagerRegistry {
    static let shared = PublishedPortManagerRegistry()
    private var manager: PublishedPortManager?

    func configure(_ manager: PublishedPortManager) { self.manager = manager }
    func clear(_ expected: PublishedPortManager) {
        guard manager === expected else { return }
        manager = nil
    }
    func reconcile(container: ContainerSnapshot) async throws {
        try await manager?.reconcile(container: container)
    }
    func close(nativeID: String) async { await manager?.close(nativeID: nativeID) }
}

/// Rewrites only the stopped container's persisted port field before Apple
/// bootstraps it. The API service intentionally reloads this file on every
/// bootstrap, so no Apple state or object identity is recreated.
enum ApplePublishedPortCompatibility {
    static func suppressNativeForwarder(
        container: ContainerSnapshot,
        appSupportURL: URL
    ) throws {
        guard container.status == .stopped, !container.configuration.publishedPorts.isEmpty else { return }
        let base = appSupportURL.appendingPathComponent("containers", isDirectory: true)
        let bundleURL = base.appendingPathComponent(container.id, isDirectory: true).standardizedFileURL
        guard bundleURL.deletingLastPathComponent() == base.standardizedFileURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let configURL = bundleURL.appendingPathComponent("config.json")
        var configuration = try JSONDecoder().decode(
            ContainerConfiguration.self,
            from: Data(contentsOf: configURL)
        )
        configuration.publishedPorts = []
        try JSONEncoder().encode(configuration).write(to: configURL, options: [.atomic])

        // This mutation is the ownership hand-off from Apple's runtime forwarder
        // to Socktainer. Make the atomic replacement durable before bootstrap so
        // a daemon/system crash cannot resurrect both listeners for the same port.
        let configFD = open(configURL.path, O_RDONLY | O_CLOEXEC)
        guard configFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { _ = close(configFD) }
        guard fsync(configFD) == 0 else { throw CocoaError(.fileWriteUnknown) }

        let directoryFD = open(bundleURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { _ = close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
