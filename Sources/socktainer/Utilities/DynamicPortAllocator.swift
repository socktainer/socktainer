import ContainerResource
import ContainerizationExtras
import Darwin
import Foundation
import Logging
import Vapor

/// Reserves Docker's dynamically allocated host ports until Apple Container
/// starts the container and binds its native `publishedPorts` forwarders.
///
/// The allocator owns no listeners and no container lifecycle state. Apple
/// owns the actual TCP/UDP forwarding, which removes the old competing host
/// listener and relay-VM architecture while preserving dynamic Docker ports.
actor DynamicPortAllocator {
    struct DynamicPortReservation: Sendable {
        fileprivate let id: UUID
        let ports: [PublishPort]
    }

    private enum Transport {
        case tcp
        case udp
    }

    private let logger: Logger
    private var pending: [UUID: [Int32]] = [:]
    private var held: [String: [Int32]] = [:]

    init(logger: Logger) {
        self.logger = logger
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
                let reservation = try reserveDynamicRange(
                    address: mapping.hostAddress.description,
                    transport: mapping.proto == .tcp ? .tcp : .udp,
                    count: Int(mapping.count)
                )
                descriptors.append(contentsOf: reservation.descriptors)
                resolved.append(
                    try PublishPort(
                        hostAddress: mapping.hostAddress,
                        hostPort: reservation.basePort,
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
        pending[id] = descriptors
        return DynamicPortReservation(id: id, ports: resolved)
    }

    /// Keeps dynamic sockets held across Docker create → start so another
    /// container cannot claim the reported port before Apple binds it.
    func commit(_ reservation: DynamicPortReservation, nativeID: String) {
        guard let descriptors = pending.removeValue(forKey: reservation.id) else { return }
        if let old = held.removeValue(forKey: nativeID) {
            for descriptor in old { _ = Darwin.close(descriptor) }
        }
        held[nativeID] = descriptors
    }

    func cancel(_ reservation: DynamicPortReservation) {
        guard let descriptors = pending.removeValue(forKey: reservation.id) else { return }
        for descriptor in descriptors { _ = Darwin.close(descriptor) }
    }

    /// Releases reservations immediately before Apple starts its native
    /// forwarders. A bind failure is then reported by the Apple API itself.
    func release(nativeID: String) {
        guard let descriptors = held.removeValue(forKey: nativeID) else { return }
        for descriptor in descriptors { _ = Darwin.close(descriptor) }
    }

    func shutdown() {
        for descriptors in Array(pending.values) + Array(held.values) {
            for descriptor in descriptors { _ = Darwin.close(descriptor) }
        }
        pending.removeAll()
        held.removeAll()
    }

    private func reserveDynamicRange(
        address: String,
        transport: Transport,
        count: Int
    ) throws -> (descriptors: [Int32], basePort: UInt16) {
        let count = max(1, count)
        for _ in 0..<128 {
            var descriptors: [Int32] = []
            do {
                let first = try Self.reserveSocket(address: address, port: 0, transport: transport)
                descriptors.append(first.fd)
                guard Int(first.port) + count - 1 <= Int(UInt16.max) else {
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
        logger.error("unable to reserve a contiguous dynamic host-port range")
        throw POSIXError(.EADDRINUSE)
    }

    private static func reserveSocket(
        address: String,
        port: UInt16,
        transport: Transport
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
}

struct DynamicPortAllocatorKey: Vapor.StorageKey {
    typealias Value = DynamicPortAllocator
}

struct DynamicPortAllocatorLifecycle: LifecycleHandler {
    let allocator: DynamicPortAllocator

    func shutdownAsync(_ application: Application) async {
        await allocator.shutdown()
        await DynamicPortAllocatorRegistry.shared.clear(allocator)
    }
}

actor DynamicPortAllocatorRegistry {
    static let shared = DynamicPortAllocatorRegistry()
    private var allocator: DynamicPortAllocator?

    func configure(_ allocator: DynamicPortAllocator) {
        self.allocator = allocator
    }

    func clear(_ expected: DynamicPortAllocator) {
        guard allocator === expected else { return }
        allocator = nil
    }

    func release(nativeID: String) async {
        await allocator?.release(nativeID: nativeID)
    }
}
