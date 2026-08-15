import Darwin
import Foundation
import Testing

@testable import GlassDock

@Suite("Persistent engine VM authority")
struct PersistentEngineTests {
    @Test("starts one custom machine and reuses one guest connection")
    func startsAndReuses() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)

        let first = try await engine.readyConnection()
        let second = try await engine.readyConnection()

        #expect(first === second)
        #expect(await machine.startCount == 1)
        #expect(await machine.connectCount == 1)
        #expect(await machine.lastPort == 1025)
        #expect(await engine.address() == "192.168.72.2")
        #expect(await engine.hostGatewayAddress() == "192.168.72.1")
        await engine.shutdown()
    }

    @Test("rejects a ping response without the guest ok payload")
    func rejectsInvalidPing() async {
        let machine = FakeEngineMachineHost(pingOK: false)
        let engine = PersistentEngine(machine: machine)

        await #expect(throws: PersistentEngineError.self) {
            _ = try await engine.readyConnection()
        }
        #expect(await machine.stopCount == 1)
    }

    @Test("coalesces concurrent readiness calls")
    func coalescesConcurrentReadiness() async throws {
        let machine = FakeEngineMachineHost(startDelay: .milliseconds(20))
        let engine = PersistentEngine(machine: machine)

        let connections = try await withThrowingTaskGroup(of: GuestConnection.self) { group in
            for _ in 0..<32 { group.addTask { try await engine.readyConnection() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(connections.allSatisfy { $0 === connections[0] })
        #expect(await machine.startCount == 1)
        #expect(await machine.connectCount == 1)
        await engine.shutdown()
    }

    @Test("waits for the guest protocol without starting another VM generation")
    func waitsForGuestProtocol() async throws {
        let machine = FakeEngineMachineHost(failedConnections: 2)
        let engine = PersistentEngine(machine: machine)

        _ = try await engine.readyConnection()

        #expect(await machine.startCount == 1)
        #expect(await machine.connectCount == 3)
        await engine.shutdown()
    }

    @Test("replaces a terminal guest connection before the next request")
    func replacesTerminalConnection() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)

        let first = try await engine.readyConnection()
        await first.close()
        let second = try await engine.readyConnection()

        #expect(first !== second)
        #expect(await machine.connectCount == 2)
        #expect(await machine.stopCount == 1)
        await engine.shutdown()
    }

    @Test("coalesces concurrent replacement of a terminal connection")
    func coalescesConcurrentTerminalReplacement() async throws {
        let machine = FakeEngineMachineHost(startDelay: .milliseconds(10))
        let engine = PersistentEngine(machine: machine)
        let first = try await engine.readyConnection()
        await first.close()

        let replacements = try await withThrowingTaskGroup(of: GuestConnection.self) { group in
            for _ in 0..<64 { group.addTask { try await engine.readyConnection() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(replacements.allSatisfy { $0 === replacements[0] })
        #expect(await machine.startCount == 2)
        #expect(await machine.connectCount == 2)
        await engine.shutdown()
    }

    @Test("stale terminal check cannot discard a concurrent replacement")
    func staleTerminalCheckPreservesConcurrentReplacement() async throws {
        let machine = FakeEngineMachineHost()
        let probe = BlockingTerminalProbe()
        let engine = PersistentEngine(
            machine: machine,
            isConnectionTerminal: { connection in await probe.check(connection) }
        )
        let first = try await engine.readyConnection()
        await first.close()
        await probe.block(connection: first)

        let staleCaller = Task { try await engine.readyConnection() }
        await probe.waitUntilBlocked()
        await engine.invalidateConnection(first)
        let replacement = try await engine.readyConnection()
        await probe.release()
        let staleResult = try await staleCaller.value

        #expect(staleResult === replacement)
        #expect(await machine.connectCount == 2)
        await engine.shutdown()
    }

    @Test("event resubscription keeps the healthy shared connection")
    func eventResubscriptionKeepsSharedConnection() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)
        let connector = PersistentEngineGuestRuntimeEventConnector(engine: engine)
        let connection = try await engine.readyConnection()

        _ = try await connector.connect()
        _ = try await connector.connect()

        #expect(!(await connection.isTerminal()))
        #expect(await machine.connectCount == 1)
        await engine.shutdown()
    }
}

private actor BlockingTerminalProbe {
    private weak var blockedConnection: GuestConnection?
    private var shouldBlock = false
    private var isBlocked = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block(connection: GuestConnection) {
        blockedConnection = connection
        shouldBlock = true
    }

    func check(_ connection: GuestConnection) async -> Bool {
        if shouldBlock, connection === blockedConnection {
            shouldBlock = false
            isBlocked = true
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return await connection.isTerminal()
    }

    func waitUntilBlocked() async {
        while !isBlocked { await Task.yield() }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FakeEngineMachineHost: EngineMachineHosting {
    private let pingOK: Bool
    private let startDelay: Duration?
    private var failedConnections: Int
    private(set) var startCount = 0
    private(set) var connectCount = 0
    private(set) var stopCount = 0
    private(set) var lastPort: UInt32?
    private var peer: FileHandle?

    init(
        pingOK: Bool = true,
        startDelay: Duration? = nil,
        failedConnections: Int = 0
    ) {
        self.pingOK = pingOK
        self.startDelay = startDelay
        self.failedConnections = failedConnections
    }

    func start() async throws -> RuntimeMachineReady {
        startCount += 1
        if let startDelay { try await Task.sleep(for: startDelay) }
        return RuntimeMachineReady(
            generation: UUID(),
            processIdentifier: 62,
            guestIPv4: "192.168.72.2",
            hostGatewayIPv4: "192.168.72.1",
            gvproxyAPI: URL(fileURLWithPath: "/tmp/gvproxy.sock")
        )
    }

    func connect(to port: UInt32) throws -> FileHandle {
        connectCount += 1
        lastPort = port
        if failedConnections > 0 {
            failedConnections -= 1
            throw POSIXError(.ECONNREFUSED)
        }
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let client = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        self.peer = peer
        let pingOK = self.pingOK
        Thread.detachNewThread {
            do {
                var codec = GuestFrameCodec()
                while true {
                    let bytes = try Self.readAvailable(peer)
                    guard !bytes.isEmpty else { return }
                    for request in try codec.append(bytes) {
                        let response = GuestFrame(
                            id: request.id,
                            kind: .response,
                            method: request.method,
                            payload: .object(["ok": .bool(pingOK)]),
                            stream: nil,
                            data: nil,
                            error: nil,
                            exitCode: nil
                        )
                        try peer.write(contentsOf: GuestFrameCodec.encode(response))
                    }
                }
            } catch {}
        }
        return client
    }

    func stop() {
        stopCount += 1
        try? peer?.close()
    }

    private nonisolated static func readAvailable(_ handle: FileHandle) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
