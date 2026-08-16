import Darwin
import Foundation
import Testing

@testable import GlassDock

@Suite("Custom VMM runtime machine")
struct RuntimeMachineTests {
    @Test("coalesces concurrent starts into one helper generation")
    func coalescesConcurrentStarts() async throws {
        let fixture = try Fixture()
        let machine = RuntimeMachine(
            configuration: fixture.configuration,
            launcher: fixture.launcher,
            socketConnector: fixture.connector,
            storagePreparer: fixture.storagePreparer
        )

        let ready = try await withThrowingTaskGroup(of: RuntimeMachineReady.self) { group in
            for _ in 0..<32 { group.addTask { try await machine.start() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(Set(ready.map(\.generation)).count == 1)
        #expect(fixture.launcher.launchCount == 1)
        #expect(fixture.storagePreparer.prepareCount == 1)
        try await machine.stop()
    }

    @Test("connects only to the active generation's vsock path")
    func connectsToGenerationScopedVsockPath() async throws {
        let fixture = try Fixture()
        let machine = RuntimeMachine(
            configuration: fixture.configuration,
            launcher: fixture.launcher,
            socketConnector: fixture.connector,
            storagePreparer: fixture.storagePreparer
        )
        let ready = try await machine.start()

        let connection = try await machine.connect(to: 1025)
        try connection.close()

        let expected = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "glassdock-vmm-\(ready.generation.uuidString.lowercased())",
                isDirectory: true
            )
            .appendingPathComponent("vsock", isDirectory: true)
            .appendingPathComponent("1025.sock", isDirectory: false)
        #expect(fixture.connector.connectedPaths == [expected.path])
        try await machine.stop()
    }

    @Test("records an unexpected helper exit and starts a new generation")
    func replacesExitedGeneration() async throws {
        let fixture = try Fixture()
        let machine = RuntimeMachine(
            configuration: fixture.configuration,
            launcher: fixture.launcher,
            socketConnector: fixture.connector,
            storagePreparer: fixture.storagePreparer
        )
        let first = try await machine.start()
        let process = try #require(fixture.launcher.lastProcess)

        await process.exit(status: 17)
        try await Task.sleep(for: .milliseconds(10))

        await #expect(
            throws: RuntimeMachineError.helperExited(
                generation: first.generation,
                status: 17,
                consoleTail: "fatal guest error\n"
            )
        ) {
            _ = try await machine.connect(to: 1025)
        }
        let second = try await machine.start()
        #expect(second.generation != first.generation)
        #expect(fixture.launcher.launchCount == 2)
        try await machine.stop()
    }

    @Test("an intentional stop does not become a crash")
    func intentionalStopIsNotCrash() async throws {
        let fixture = try Fixture()
        let machine = RuntimeMachine(
            configuration: fixture.configuration,
            launcher: fixture.launcher,
            socketConnector: fixture.connector,
            storagePreparer: fixture.storagePreparer
        )
        _ = try await machine.start()

        let runtimeDirectory = fixture.launcher.lastRuntimeDirectory
        #expect(runtimeDirectory.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        try await machine.stop()

        #expect(runtimeDirectory.map { FileManager.default.fileExists(atPath: $0.path) } == false)

        await #expect(throws: RuntimeMachineError.notRunning) {
            _ = try await machine.connect(to: 1025)
        }
    }

    @Test("startup failure captures console tail and removes its runtime directory")
    func failedStartCleansRuntimeDirectory() async throws {
        let fixture = try Fixture()
        fixture.launcher.failReadiness = true
        let machine = RuntimeMachine(
            configuration: fixture.configuration,
            launcher: fixture.launcher,
            socketConnector: fixture.connector,
            storagePreparer: fixture.storagePreparer
        )

        do {
            _ = try await machine.start()
            Issue.record("expected helper startup failure")
        } catch let RuntimeMachineError.helperExited(_, status, consoleTail) {
            #expect(status == 23)
            #expect(consoleTail == "startup failed\n")
        }
        let runtimeDirectory = try #require(fixture.launcher.lastRuntimeDirectory)
        #expect(!FileManager.default.fileExists(atPath: runtimeDirectory.path))
    }

    @Test("uses the custom helper's exact command-line contract")
    func helperArguments() throws {
        let fixture = try Fixture()
        let runtimeDirectory = fixture.configuration.stateDirectory
            .appendingPathComponent("runtime/generation", isDirectory: true)

        let arguments = FoundationRuntimeMachineProcessLauncher.arguments(
            configuration: fixture.configuration,
            runtimeDirectory: runtimeDirectory
        )

        #expect(
            arguments == [
                "--parent-pid", String(Darwin.getpid()),
                "--kernel", "/tmp/kernel",
                "--root-disk", "/tmp/root.ext4",
                "--data-disk", fixture.configuration.dataDisk.path,
                "--bind-source", fixture.configuration.bindSource.path,
                "--excluded-bind-source", fixture.configuration.stateDirectory.path,
                "--control-socket", runtimeDirectory.appendingPathComponent("vsock/1025.sock").path,
                "--tcp-relay-socket", runtimeDirectory.appendingPathComponent("vsock/1026.sock").path,
                "--console-log", runtimeDirectory.appendingPathComponent("console.log").path,
                "--cpus", "4",
                "--memory-mib", "1024",
            ])
    }

    @Test("permits engine state isolated from the exported host source")
    func permitsIsolatedEngineState() throws {
        _ = try RuntimeMachineConfiguration(
            helperExecutable: URL(fileURLWithPath: "/tmp/glassdock-vmm"),
            stateDirectory: URL(fileURLWithPath: "/private/state", isDirectory: true),
            kernel: URL(fileURLWithPath: "/tmp/kernel"),
            rootDisk: URL(fileURLWithPath: "/tmp/root.ext4"),
            dataDisk: URL(fileURLWithPath: "/private/state/data.ext4"),
            bindSource: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            cpuCount: 4,
            memoryBytes: 1024 * 1024 * 1024
        )
    }

    @Test(
        "rejects resource values unsupported by the VMM helper",
        arguments: [
            (0, UInt64(1024 * 1024 * 1024)),
            (65, UInt64(1024 * 1024 * 1024)),
            (4, UInt64(95 * 1024 * 1024)),
            (4, UInt64(65_537 * 1024 * 1024)),
        ])
    func rejectsUnsupportedResources(cpuCount: Int, memoryBytes: UInt64) {
        #expect(throws: RuntimeMachineError.self) {
            _ = try RuntimeMachineConfiguration(
                helperExecutable: URL(fileURLWithPath: "/tmp/glassdock-vmm"),
                stateDirectory: URL(fileURLWithPath: "/private/state", isDirectory: true),
                kernel: URL(fileURLWithPath: "/tmp/kernel"),
                rootDisk: URL(fileURLWithPath: "/tmp/root.ext4"),
                dataDisk: URL(fileURLWithPath: "/private/state/data.ext4"),
                bindSource: URL(fileURLWithPath: "/Users/test", isDirectory: true),
                cpuCount: cpuCount,
                memoryBytes: memoryBytes
            )
        }
    }
}

private struct Fixture {
    let configuration: RuntimeMachineConfiguration
    let launcher = FakeRuntimeMachineProcessLauncher()
    let connector = FakeRuntimeMachineSocketConnector()
    let storagePreparer = FakeRuntimeMachineStoragePreparer()

    init() throws {
        let bindSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-runtime-machine-\(UUID().uuidString)", isDirectory: true)
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-engine-\(UUID().uuidString)", isDirectory: true)
        configuration = try RuntimeMachineConfiguration(
            helperExecutable: URL(fileURLWithPath: "/tmp/glassdock-vmm"),
            stateDirectory: state,
            kernel: URL(fileURLWithPath: "/tmp/kernel"),
            rootDisk: URL(fileURLWithPath: "/tmp/root.ext4"),
            dataDisk: state.appendingPathComponent("data.ext4", isDirectory: false),
            bindSource: bindSource,
            cpuCount: 4,
            memoryBytes: 1024 * 1024 * 1024
        )
    }
}

private final class FakeRuntimeMachineStoragePreparer: RuntimeMachineStoragePreparing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var preparations = 0

    var prepareCount: Int { lock.withLock { preparations } }

    func prepareDataDisk(at url: URL) throws {
        lock.withLock { preparations += 1 }
    }
}

private final class FakeRuntimeMachineProcessLauncher: RuntimeMachineProcessLaunching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var launches = 0
    private var process: FakeRuntimeMachineProcess?
    private var runtimeDirectory: URL?

    var launchCount: Int { lock.withLock { launches } }
    var lastProcess: FakeRuntimeMachineProcess? { lock.withLock { process } }
    var lastRuntimeDirectory: URL? { lock.withLock { runtimeDirectory } }
    var failReadiness = false

    func launch(
        configuration: RuntimeMachineConfiguration,
        generation: UUID,
        runtimeDirectory: URL
    ) throws -> any RuntimeMachineProcess {
        let console = failReadiness ? "startup failed\n" : "fatal guest error\n"
        try Data(console.utf8).write(to: runtimeDirectory.appendingPathComponent("console.log"))
        try Data(
            "{\"guestAddress\":\"192.168.72.2/24\",\"gateway\":\"192.168.72.1\"}"
                .utf8
        ).write(to: runtimeDirectory.appendingPathComponent("network.json"))
        let process = FakeRuntimeMachineProcess(
            processIdentifier: Int32(10_000 + launchCount),
            readinessFailureStatus: failReadiness ? 23 : nil
        )
        lock.withLock {
            launches += 1
            self.process = process
            self.runtimeDirectory = runtimeDirectory
        }
        return process
    }
}

private actor FakeRuntimeMachineProcess: RuntimeMachineProcess {
    nonisolated let processIdentifier: Int32
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private let readinessFailureStatus: Int32?

    init(processIdentifier: Int32, readinessFailureStatus: Int32? = nil) {
        self.processIdentifier = processIdentifier
        self.readinessFailureStatus = readinessFailureStatus
    }

    func waitUntilReady(generation: UUID) async throws {
        try await Task.sleep(for: .milliseconds(5))
        if let readinessFailureStatus {
            throw RuntimeMachineError.helperExited(
                generation: generation,
                status: readinessFailureStatus,
                consoleTail: nil
            )
        }
    }

    func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    func stop() async throws {
        exit(status: 0)
    }

    func exit(status: Int32) {
        guard exitStatus == nil else { return }
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: status) }
    }
}

private final class FakeRuntimeMachineSocketConnector: RuntimeMachineSocketConnecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var paths: [String] = []
    private var peers: [FileHandle] = []

    var connectedPaths: [String] { lock.withLock { paths } }

    func connect(to url: URL) throws -> FileHandle {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let connection = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        lock.withLock {
            paths.append(url.path)
            peers.append(peer)
        }
        return connection
    }

    func connect(toIPv4 address: String, port: UInt16) throws -> FileHandle {
        try connect(to: URL(fileURLWithPath: "\(address)-\(port)"))
    }
}
