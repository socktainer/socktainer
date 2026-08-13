import Darwin
import Logging
import Testing
import VaporTesting

@testable import socktainer

@Suite("Direct TCP port forwarder", .serialized)
struct DirectTCPPortForwarderTests {
    @Test("add and remove are idempotent")
    func addAndRemoveAreIdempotent() async throws {
        let factory = RecordingTCPListenerFactory()
        let forwarder = DirectTCPPortForwarder(
            factory: factory,
            logger: Logger(label: "socktainer.tests.direct-tcp")
        )
        let mapping = Self.mapping(id: "web", hostPort: 20_080, guestPort: 80)

        try await forwarder.add(mapping)
        try await forwarder.add(mapping)
        #expect(await factory.startedMappings() == [mapping])
        #expect(await forwarder.mappings() == [mapping])

        try await forwarder.remove(id: mapping.id)
        try await forwarder.remove(id: mapping.id)
        #expect(await factory.closedIdentifiers() == [mapping.id])
        #expect(await forwarder.mappings().isEmpty)
    }

    @Test("reconcile adds, replaces, and removes publications")
    func reconcileAppliesDesiredState() async throws {
        let factory = RecordingTCPListenerFactory()
        let forwarder = DirectTCPPortForwarder(
            factory: factory,
            logger: Logger(label: "socktainer.tests.direct-tcp")
        )
        let first = Self.mapping(id: "first", hostPort: 21_001, guestPort: 81)
        let oldSecond = Self.mapping(id: "second", hostPort: 21_002, guestPort: 82)
        let newSecond = Self.mapping(id: "second", hostPort: 21_002, guestPort: 8_082)
        let third = Self.mapping(id: "third", hostPort: 21_003, guestPort: 83)

        try await forwarder.reconcile([first, oldSecond])
        try await forwarder.reconcile([newSecond, third])

        #expect(await forwarder.mappings() == [newSecond, third])
        #expect(Set(await factory.closedIdentifiers()) == ["first", "second"])
        #expect(await factory.startedMappings() == [first, oldSecond, newSecond, third])
    }

    @Test("failed reconcile restores the previous publications")
    func failedReconcileRollsBack() async throws {
        let factory = RecordingTCPListenerFactory()
        let forwarder = DirectTCPPortForwarder(
            factory: factory,
            logger: Logger(label: "socktainer.tests.direct-tcp")
        )
        let original = Self.mapping(id: "web", hostPort: 22_001, guestPort: 80)
        let replacement = Self.mapping(id: "web", hostPort: 22_001, guestPort: 8_080)
        let failing = Self.mapping(id: "fail", hostPort: 22_002, guestPort: 82)
        try await forwarder.add(original)
        await factory.failNextStart(id: failing.id)

        await #expect(throws: DirectTCPPortForwarderError.self) {
            try await forwarder.reconcile([replacement, failing])
        }

        #expect(await forwarder.mappings() == [original])
    }

    @Test("failed removal restores publications closed earlier in the update")
    func failedRemovalRollsBack() async throws {
        let factory = RecordingTCPListenerFactory()
        let forwarder = DirectTCPPortForwarder(
            factory: factory,
            logger: Logger(label: "socktainer.tests.direct-tcp")
        )
        let first = Self.mapping(id: "first", hostPort: 22_101, guestPort: 80)
        let second = Self.mapping(id: "second", hostPort: 22_102, guestPort: 81)
        try await forwarder.reconcile([first, second])
        await factory.failNextClose(id: second.id)

        await #expect(throws: DirectTCPPortForwarderError.self) {
            try await forwarder.reconcile([])
        }

        #expect(await forwarder.mappings() == [first, second])
        #expect(await factory.startedMappings() == [first, second, first])
    }

    @Test("duplicate identifiers and host endpoints are rejected before changes")
    func duplicateDesiredStateIsRejected() async throws {
        let factory = RecordingTCPListenerFactory()
        let forwarder = DirectTCPPortForwarder(
            factory: factory,
            logger: Logger(label: "socktainer.tests.direct-tcp")
        )
        let first = Self.mapping(id: "first", hostPort: 23_001, guestPort: 80)

        await #expect(
            throws: DirectTCPPortForwarderError.duplicateIdentifier("first")
        ) {
            try await forwarder.reconcile([first, first])
        }
        await #expect(
            throws: DirectTCPPortForwarderError.duplicateHostEndpoint(
                address: "127.0.0.1",
                port: 23_001
            )
        ) {
            try await forwarder.reconcile([
                first,
                Self.mapping(id: "second", hostPort: 23_001, guestPort: 81),
            ])
        }
        #expect(await factory.startedMappings().isEmpty)
    }

    @Test("real listener forwards bytes directly to the configured guest endpoint")
    func forwardsBytesOverLoopback() async throws {
        try await withApp { app in
            let frontendPort = try Self.availableTCPPort()
            let forwarder = DirectTCPPortForwarder(
                eventLoopGroup: app.eventLoopGroup,
                dialer: LoopbackGuestProxyDialer(),
                logger: Logger(label: "socktainer.tests.direct-tcp.integration")
            )
            let mapping = Self.mapping(
                id: "echo",
                hostPort: frontendPort,
                guestPort: 42_000
            )

            try await forwarder.add(mapping)
            let response: Data
            do {
                response = try await Task.detached {
                    try Self.roundTrip(port: frontendPort, payload: Data("direct-vm-path".utf8))
                }.value
            } catch {
                try? await forwarder.remove(id: mapping.id)
                throw error
            }

            #expect(response == Data("direct-vm-path".utf8))
            try await forwarder.remove(id: mapping.id)
        }
    }

    @Test("kernel-selected host port is returned and forwards bytes")
    func dynamicHostPort() async throws {
        try await withApp { app in
            let forwarder = DirectTCPPortForwarder(
                eventLoopGroup: app.eventLoopGroup,
                dialer: LoopbackGuestProxyDialer(),
                logger: Logger(label: "socktainer.tests.direct-tcp.dynamic")
            )
            let requested = Self.mapping(id: "dynamic", hostPort: 0, guestPort: 42_001)

            let published = try await forwarder.add(requested)
            #expect(published.hostPort > 0)
            let response: Data
            do {
                response = try await Task.detached {
                    try Self.roundTrip(
                        port: published.hostPort,
                        payload: Data("dynamic-port".utf8)
                    )
                }.value
            } catch {
                try? await forwarder.remove(id: requested.id)
                throw error
            }
            #expect(response == Data("dynamic-port".utf8))
            try await forwarder.remove(id: requested.id)
        }
    }

    @Test("client write half-close preserves the backend response")
    func clientHalfClose() async throws {
        try await withApp { app in
            let forwarder = DirectTCPPortForwarder(
                eventLoopGroup: app.eventLoopGroup,
                dialer: HalfCloseGuestProxyDialer(),
                logger: Logger(label: "socktainer.tests.direct-tcp.half-close")
            )
            let mapping = Self.mapping(id: "half-close", hostPort: 0, guestPort: 42_002)
            let published = try await forwarder.add(mapping)

            let response: Data
            do {
                response = try await Task.detached {
                    try Self.roundTrip(
                        port: published.hostPort,
                        payload: Data("request-before-eof".utf8),
                        halfClose: true
                    )
                }.value
            } catch {
                try? await forwarder.remove(id: mapping.id)
                throw error
            }

            #expect(response == Data("request-before-eof".utf8))
            try await forwarder.remove(id: mapping.id)
        }
    }

    private static func mapping(
        id: String,
        hostPort: Int,
        guestPort: Int
    ) -> DirectTCPPortMapping {
        DirectTCPPortMapping(
            id: id,
            hostAddress: "127.0.0.1",
            hostPort: hostPort,
            guestPort: guestPort
        )
    }

    private static func availableTCPPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard found == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func roundTrip(port: Int, payload: Data, halfClose: Bool = false) throws -> Data {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try payload.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                guard count > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
        if halfClose {
            guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        var buffer = [UInt8](repeating: 0, count: payload.count)
        var received = 0
        while received < buffer.count {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: received),
                    bytes.count - received
                )
            }
            guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            received += count
        }
        return Data(buffer)
    }
}

private struct HalfCloseGuestProxyDialer: GuestPortConnectionDialing {
    func dial() async throws -> FileHandle {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let client = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peer = descriptors[1]
        Thread.detachNewThread {
            defer { _ = Darwin.close(peer) }
            var header = [UInt8](repeating: 0, count: 7)
            guard Darwin.read(peer, &header, header.count) == header.count,
                header.prefix(5) == [0x53, 0x54, 0x50, 0x31, 0x01]
            else { return }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(peer, &buffer, buffer.count)
                guard count >= 0 else { return }
                if count == 0 { break }
                request.append(buffer, count: count)
            }
            request.withUnsafeBytes { bytes in
                _ = Darwin.write(peer, bytes.baseAddress, bytes.count)
            }
            _ = Darwin.shutdown(peer, SHUT_WR)
        }
        return client
    }
}

private actor RecordingTCPListenerFactory: DirectTCPListenerFactory {
    enum Failure: Error { case requested }

    private var starts: [DirectTCPPortMapping] = []
    private var closes: [String] = []
    private var failingStartIdentifiers: Set<String> = []
    private var failingCloseIdentifiers: Set<String> = []

    func start(_ mapping: DirectTCPPortMapping) async throws -> any DirectTCPListenerHandle {
        if failingStartIdentifiers.remove(mapping.id) != nil {
            throw Failure.requested
        }
        starts.append(mapping)
        return RecordingTCPListenerHandle(
            id: mapping.id,
            boundPort: mapping.hostPort,
            factory: self
        )
    }

    func recordClose(id: String) throws {
        if failingCloseIdentifiers.remove(id) != nil {
            throw Failure.requested
        }
        closes.append(id)
    }

    func failNextStart(id: String) { failingStartIdentifiers.insert(id) }
    func failNextClose(id: String) { failingCloseIdentifiers.insert(id) }
    func startedMappings() -> [DirectTCPPortMapping] { starts }
    func closedIdentifiers() -> [String] { closes }
}

private struct RecordingTCPListenerHandle: DirectTCPListenerHandle {
    let id: String
    let boundPort: Int
    let factory: RecordingTCPListenerFactory

    func close() async throws { try await factory.recordClose(id: id) }
}

private struct LoopbackGuestProxyDialer: GuestPortConnectionDialing {
    func dial() async throws -> FileHandle {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let client = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peer = descriptors[1]
        Thread.detachNewThread {
            defer { _ = Darwin.close(peer) }
            var header = [UInt8](repeating: 0, count: 7)
            guard Darwin.read(peer, &header, header.count) == header.count,
                header.prefix(5) == [0x53, 0x54, 0x50, 0x31, 0x01]
            else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(peer, &buffer, buffer.count)
                guard count > 0 else { return }
                _ = Darwin.write(peer, buffer, count)
            }
        }
        return client
    }
}
