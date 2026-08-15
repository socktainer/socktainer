import Foundation

enum RuntimeMachineError: Error, Equatable {
    case invalidConfiguration(String)
    case notRunning
    case helperExited(generation: UUID, status: Int32, consoleTail: String?)
    case helperLaunch(String)
    case invalidReadiness(String)
    case socketConnect(path: String, errno: Int32)
}

struct RuntimeMachineConfiguration: Sendable, Equatable {
    static let defaultCPUCount = 6
    static let maximumCPUCount = 64
    static let defaultMemoryBytes: UInt64 = 1024 * 1024 * 1024
    static let minimumMemoryBytes: UInt64 = 96 * 1024 * 1024
    static let maximumMemoryBytes: UInt64 = 65_536 * 1024 * 1024

    let helperExecutable: URL
    let stateDirectory: URL
    let kernel: URL
    let rootDisk: URL
    let dataDisk: URL
    let bindSource: URL
    let cpuCount: Int
    let memoryBytes: UInt64

    init(
        helperExecutable: URL,
        stateDirectory: URL,
        kernel: URL,
        rootDisk: URL,
        dataDisk: URL,
        bindSource: URL,
        cpuCount: Int,
        memoryBytes: UInt64
    ) throws {
        let paths = [helperExecutable, stateDirectory, kernel, rootDisk, dataDisk, bindSource]
        guard paths.allSatisfy({ $0.path.hasPrefix("/") }) else {
            throw RuntimeMachineError.invalidConfiguration("all machine paths must be absolute")
        }
        let normalizedStateDirectory = canonicalFileURL(stateDirectory)
        let normalizedBindSource = canonicalFileURL(bindSource)
        let normalizedDataDisk = canonicalFileURL(dataDisk)
        guard normalizedStateDirectory.path != normalizedBindSource.path,
            !normalizedBindSource.path.hasPrefix(normalizedStateDirectory.path + "/"),
            !normalizedStateDirectory.path.hasPrefix(normalizedBindSource.path + "/"),
            normalizedDataDisk.path.hasPrefix(normalizedStateDirectory.path + "/")
        else {
            throw RuntimeMachineError.invalidConfiguration(
                "engine state and host bind source must not overlap, and the data disk must be inside engine state"
            )
        }
        guard (1...Self.maximumCPUCount).contains(cpuCount) else {
            throw RuntimeMachineError.invalidConfiguration(
                "CPU count must be between 1 and \(Self.maximumCPUCount)"
            )
        }
        guard (Self.minimumMemoryBytes...Self.maximumMemoryBytes).contains(memoryBytes) else {
            throw RuntimeMachineError.invalidConfiguration(
                "memory must be between \(Self.minimumMemoryBytes) and \(Self.maximumMemoryBytes) bytes"
            )
        }
        guard memoryBytes.isMultiple(of: 1024 * 1024) else {
            throw RuntimeMachineError.invalidConfiguration(
                "memory must be a whole number of MiB"
            )
        }
        self.helperExecutable = helperExecutable.standardizedFileURL
        self.stateDirectory = normalizedStateDirectory
        self.kernel = kernel.standardizedFileURL
        self.rootDisk = rootDisk.standardizedFileURL
        self.dataDisk = normalizedDataDisk
        self.bindSource = normalizedBindSource
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
    }
}

struct RuntimeMachineReady: Sendable, Equatable {
    let generation: UUID
    let processIdentifier: Int32
    let guestIPv4: String
    let hostGatewayIPv4: String
    let gvproxyAPI: URL
}

private struct RuntimeMachineNetworkState: Decodable {
    let guestAddress: String
    let gateway: String
}

protocol EngineMachineHosting: Sendable {
    func start() async throws -> RuntimeMachineReady
    func connect(to port: UInt32) async throws -> FileHandle
    func stop() async throws
}

/// Owns one custom Hypervisor.framework helper generation.
///
/// The helper owns the VM and every virtio device. This actor owns only helper
/// supervision and host connections to the helper's generation-scoped vsock
/// sockets.
actor RuntimeMachine: EngineMachineHosting {
    private struct StartOperation {
        let token: UUID
        let task: Task<RunningGeneration, Error>
    }

    private struct RunningGeneration: Sendable {
        let ready: RuntimeMachineReady
        let runtimeDirectory: URL
        let process: any RuntimeMachineProcess
    }

    private let configuration: RuntimeMachineConfiguration
    private let launcher: any RuntimeMachineProcessLaunching
    private let socketConnector: any RuntimeMachineSocketConnecting
    private let storagePreparer: any RuntimeMachineStoragePreparing
    private var startOperation: StartOperation?
    private var running: RunningGeneration?
    private var lastUnexpectedExit: (generation: UUID, status: Int32, consoleTail: String?)?

    init(configuration: RuntimeMachineConfiguration) {
        self.init(
            configuration: configuration,
            launcher: FoundationRuntimeMachineProcessLauncher(),
            socketConnector: DarwinRuntimeMachineSocketConnector(),
            storagePreparer: FoundationRuntimeMachineStoragePreparer()
        )
    }

    init(
        configuration: RuntimeMachineConfiguration,
        launcher: any RuntimeMachineProcessLaunching,
        socketConnector: any RuntimeMachineSocketConnecting,
        storagePreparer: any RuntimeMachineStoragePreparing = FoundationRuntimeMachineStoragePreparer()
    ) {
        self.configuration = configuration
        self.launcher = launcher
        self.socketConnector = socketConnector
        self.storagePreparer = storagePreparer
    }

    func start() async throws -> RuntimeMachineReady {
        if let running { return running.ready }

        let operation: StartOperation
        if let startOperation {
            operation = startOperation
        } else {
            let token = UUID()
            let configuration = self.configuration
            let launcher = self.launcher
            let storagePreparer = self.storagePreparer
            operation = StartOperation(
                token: token,
                task: Task {
                    try await Self.launch(
                        configuration: configuration,
                        generation: token,
                        launcher: launcher,
                        storagePreparer: storagePreparer
                    )
                }
            )
            startOperation = operation
        }

        do {
            let generation = try await operation.task.value
            if running?.ready.generation == generation.ready.generation {
                return generation.ready
            }
            guard startOperation?.token == operation.token else {
                try await generation.process.stop()
                Self.removeRuntimeDirectory(generation.runtimeDirectory)
                throw CancellationError()
            }
            startOperation = nil
            running = generation
            lastUnexpectedExit = nil
            supervise(generation)
            return generation.ready
        } catch {
            if startOperation?.token == operation.token { startOperation = nil }
            throw error
        }
    }

    func connect(to port: UInt32) async throws -> FileHandle {
        guard port > 0 else {
            throw RuntimeMachineError.invalidConfiguration("vsock port must be positive")
        }
        guard let running else {
            if let lastUnexpectedExit {
                throw RuntimeMachineError.helperExited(
                    generation: lastUnexpectedExit.generation,
                    status: lastUnexpectedExit.status,
                    consoleTail: lastUnexpectedExit.consoleTail
                )
            }
            throw RuntimeMachineError.notRunning
        }
        let path = running.runtimeDirectory
            .appendingPathComponent("vsock", isDirectory: true)
            .appendingPathComponent("\(port).sock", isDirectory: false)
        return try socketConnector.connect(to: path)
    }

    func stop() async throws {
        if let startOperation {
            startOperation.task.cancel()
            self.startOperation = nil
        }
        guard let running else { return }
        self.running = nil
        do {
            try await running.process.stop()
        } catch {
            Self.removeRuntimeDirectory(running.runtimeDirectory)
            throw error
        }
        Self.removeRuntimeDirectory(running.runtimeDirectory)
    }

    private static func launch(
        configuration: RuntimeMachineConfiguration,
        generation: UUID,
        launcher: any RuntimeMachineProcessLaunching,
        storagePreparer: any RuntimeMachineStoragePreparing
    ) async throws -> RunningGeneration {
        try storagePreparer.prepareDataDisk(at: configuration.dataDisk)
        // Darwin limits Unix socket paths to 103 bytes. Keep ephemeral helper
        // sockets in the system temporary directory; durable disks stay in the
        // private state directory.
        let runtimeDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "glassdock-vmm-\(generation.uuidString.lowercased())",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: runtimeDirectory.appendingPathComponent("vsock", isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let process = try launcher.launch(
                configuration: configuration,
                generation: generation,
                runtimeDirectory: runtimeDirectory
            )
            do {
                try await process.waitUntilReady(generation: generation)
            } catch {
                try? await process.stop()
                if let runtimeError = error as? RuntimeMachineError,
                    case .helperExited(_, let status, _) = runtimeError
                {
                    throw RuntimeMachineError.helperExited(
                        generation: generation,
                        status: status,
                        consoleTail: consoleTail(in: runtimeDirectory)
                    )
                }
                throw error
            }
            let networkStateURL = runtimeDirectory.appendingPathComponent("network.json")
            let networkState: RuntimeMachineNetworkState
            do {
                networkState = try JSONDecoder().decode(
                    RuntimeMachineNetworkState.self,
                    from: Data(contentsOf: networkStateURL)
                )
            } catch {
                try? await process.stop()
                throw RuntimeMachineError.invalidReadiness(
                    "VMM helper did not publish valid network state: \(error)"
                )
            }
            guard let guestIPv4 = networkState.guestAddress.split(separator: "/").first,
                !guestIPv4.isEmpty,
                !networkState.gateway.isEmpty
            else {
                try? await process.stop()
                throw RuntimeMachineError.invalidReadiness(
                    "VMM helper published invalid IPv4 topology"
                )
            }
            return RunningGeneration(
                ready: RuntimeMachineReady(
                    generation: generation,
                    processIdentifier: process.processIdentifier,
                    guestIPv4: String(guestIPv4),
                    hostGatewayIPv4: networkState.gateway,
                    gvproxyAPI: runtimeDirectory.appendingPathComponent("network/a.sock")
                ),
                runtimeDirectory: runtimeDirectory,
                process: process
            )
        } catch {
            removeRuntimeDirectory(runtimeDirectory)
            throw error
        }
    }

    private func supervise(_ generation: RunningGeneration) {
        Task { [weak self] in
            let status = await generation.process.waitForExit()
            await self?.recordExit(generation: generation, status: status)
        }
    }

    private func recordExit(generation: RunningGeneration, status: Int32) {
        guard running?.ready.generation == generation.ready.generation else { return }
        let consoleTail = Self.consoleTail(in: generation.runtimeDirectory)
        running = nil
        lastUnexpectedExit = (generation.ready.generation, status, consoleTail)
        Self.removeRuntimeDirectory(generation.runtimeDirectory)
    }

    private static func consoleTail(in runtimeDirectory: URL) -> String? {
        let console = runtimeDirectory.appendingPathComponent("console.log")
        guard let data = try? Data(contentsOf: console), !data.isEmpty else { return nil }
        return String(decoding: data.suffix(8 * 1024), as: UTF8.self)
    }

    private static func removeRuntimeDirectory(_ runtimeDirectory: URL) {
        try? FileManager.default.removeItem(at: runtimeDirectory)
    }
}

extension Data {
    fileprivate init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
