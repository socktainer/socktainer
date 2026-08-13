import Foundation
import Testing

@testable import socktainer

@Suite("Persistent engine VM authority")
struct PersistentEngineTests {
    @Test("provisions and boots exactly one machine, then reuses one guest connection")
    func provisionsBootsAndReuses() async throws {
        let controller = FakeEngineMachineController()
        let engine = PersistentEngine(controller: controller)

        let first = try await engine.readyConnection()
        let second = try await engine.readyConnection()

        #expect(first === second)
        #expect(await controller.provisionCount() == 1)
        #expect(await controller.bootCount() == 1)
        #expect(await controller.dialCount() == 1)
        #expect(await controller.lastDialPort() == 1025)
        #expect(await engine.address() == "192.168.64.2")
        await engine.invalidateConnection()
        await controller.close()
    }

    @Test("rejects a ping response without the guest ok payload")
    func rejectsInvalidPing() async {
        let controller = FakeEngineMachineController(pingOK: false)
        let engine = PersistentEngine(controller: controller)

        await #expect(throws: PersistentEngineError.self) {
            _ = try await engine.readyConnection()
        }
        await controller.close()
    }

    @Test("coalesces concurrent readiness calls")
    func coalescesConcurrentReadiness() async throws {
        let controller = FakeEngineMachineController(provisionDelay: .milliseconds(20))
        let engine = PersistentEngine(controller: controller)

        let connections = try await withThrowingTaskGroup(of: GuestConnection.self) { group in
            for _ in 0..<32 {
                group.addTask { try await engine.readyConnection() }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(connections.allSatisfy { $0 === connections[0] })
        #expect(await controller.provisionCount() == 1)
        #expect(await controller.bootCount() == 1)
        #expect(await controller.dialCount() == 1)
        await engine.invalidateConnection()
        await controller.close()
    }

    @Test("work expands guest memory and idle time returns it to the host")
    func workCapacityIsReclaimed() async throws {
        let controller = FakeEngineMachineController()
        let engine = PersistentEngine(controller: controller)
        _ = try await engine.readyConnection()

        try await engine.prepareForWork()
        await engine.finishedWork()
        try await Task.sleep(for: .milliseconds(300))

        #expect(
            await controller.memoryTargets() == [
                PersistentEngine.idleMemoryBytes,
                PersistentEngine.configuredMemoryBytes,
                PersistentEngine.idleMemoryBytes,
            ]
        )
        await engine.invalidateConnection()
        await controller.close()
    }

    @Test("failed memory expansion does not leave a phantom active request")
    func failedMemoryExpansionRollsBack() async throws {
        let controller = FakeEngineMachineController(failingTarget: PersistentEngine.configuredMemoryBytes)
        let engine = PersistentEngine(controller: controller)
        _ = try await engine.readyConnection()

        await #expect(throws: TestEngineError.memoryTarget) {
            try await engine.prepareForWork()
        }
        await controller.allowMemoryTargets()
        try await engine.prepareForWork()

        #expect(
            await controller.memoryTargets() == [
                PersistentEngine.idleMemoryBytes,
                PersistentEngine.configuredMemoryBytes,
                PersistentEngine.configuredMemoryBytes,
            ]
        )
        await engine.finishedWork()
        await engine.invalidateConnection()
        await controller.close()
    }
}

private enum TestEngineError: Error { case memoryTarget }

private actor FakeEngineMachineController: EngineMachineControlling {
    private let pingOK: Bool
    private let provisionDelay: Duration?
    private var provisioned = false
    private var running = false
    private var provisions = 0
    private var boots = 0
    private var dials = 0
    private var dialPort: UInt32?
    private var peer: FileHandle?
    private var targets: [UInt64] = []
    private var failingTarget: UInt64?

    init(pingOK: Bool = true, provisionDelay: Duration? = nil, failingTarget: UInt64? = nil) {
        self.pingOK = pingOK
        self.provisionDelay = provisionDelay
        self.failingTarget = failingTarget
    }

    func inspect(id: String) -> EngineMachine? {
        guard provisioned else { return nil }
        return EngineMachine(
            id: id,
            containerID: running ? "engine-backing-container" : "",
            ipAddress: running ? "192.168.64.2" : "",
            running: running
        )
    }

    func provision(id: String) async throws {
        provisions += 1
        if let provisionDelay { try await Task.sleep(for: provisionDelay) }
        provisioned = true
    }

    func boot(id: String) -> EngineMachine {
        boots += 1
        running = true
        return EngineMachine(
            id: id,
            containerID: "engine-backing-container",
            ipAddress: "192.168.64.2",
            running: true
        )
    }

    func dial(containerID: String, port: UInt32) throws -> FileHandle {
        dials += 1
        dialPort = port
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

    func setMemoryTarget(_ bytes: UInt64) throws {
        targets.append(bytes)
        if bytes == failingTarget { throw TestEngineError.memoryTarget }
    }

    func allowMemoryTargets() { failingTarget = nil }

    func stop(id: String) {}

    func provisionCount() -> Int { provisions }
    func bootCount() -> Int { boots }
    func dialCount() -> Int { dials }
    func lastDialPort() -> UInt32? { dialPort }
    func memoryTargets() -> [UInt64] { targets }

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

    func close() {
        try? peer?.close()
    }
}
