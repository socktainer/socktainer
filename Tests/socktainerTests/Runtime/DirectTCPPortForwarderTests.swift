import Darwin
import Logging
import Testing
import VaporTesting

@testable import socktainer

@Suite("Direct TCP port forwarder")
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
            let backend = try LoopbackEchoServer.start()
            defer { backend.close() }
            let frontendPort = try Self.availableTCPPort()
            let forwarder = DirectTCPPortForwarder(
                eventLoopGroup: app.eventLoopGroup,
                logger: Logger(label: "socktainer.tests.direct-tcp.integration")
            )
            let mapping = Self.mapping(
                id: "echo",
                hostPort: frontendPort,
                guestPort: backend.port
            )

            try await forwarder.add(mapping)
            let response = try await Task.detached {
                try Self.roundTrip(port: frontendPort, payload: Data("direct-vm-path".utf8))
            }.value

            #expect(response == Data("direct-vm-path".utf8))
            try await forwarder.remove(id: mapping.id)
        }
    }

    @Test("kernel-selected host port is returned and forwards bytes")
    func dynamicHostPort() async throws {
        try await withApp { app in
            let backend = try LoopbackEchoServer.start()
            defer { backend.close() }
            let forwarder = DirectTCPPortForwarder(
                eventLoopGroup: app.eventLoopGroup,
                logger: Logger(label: "socktainer.tests.direct-tcp.dynamic")
            )
            let requested = Self.mapping(id: "dynamic", hostPort: 0, guestPort: backend.port)

            let published = try await forwarder.add(requested)
            #expect(published.hostPort > 0)
            let response = try await Task.detached {
                try Self.roundTrip(
                    port: published.hostPort,
                    payload: Data("dynamic-port".utf8)
                )
            }.value
            #expect(response == Data("dynamic-port".utf8))
            try await forwarder.remove(id: requested.id)
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
            guestAddress: "127.0.0.1",
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

    private static func roundTrip(port: Int, payload: Data) throws -> Data {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
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
            guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        var buffer = [UInt8](repeating: 0, count: payload.count)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count == payload.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return Data(buffer)
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

private final class LoopbackEchoServer: @unchecked Sendable {
    let descriptor: Int32
    let port: Int
    private let task: Task<Void, Never>

    private init(descriptor: Int32, port: Int, task: Task<Void, Never>) {
        self.descriptor = descriptor
        self.port = port
        self.task = task
    }

    static func start() throws -> LoopbackEchoServer {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            _ = Darwin.close(descriptor)
            throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        let task = Task.detached {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { _ = Darwin.close(client) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                _ = Darwin.write(client, buffer, count)
            }
        }
        return LoopbackEchoServer(
            descriptor: descriptor,
            port: Int(UInt16(bigEndian: address.sin_port)),
            task: task
        )
    }

    func close() {
        _ = Darwin.close(descriptor)
        task.cancel()
    }
}
