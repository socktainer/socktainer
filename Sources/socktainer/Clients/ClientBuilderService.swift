import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import NIO
import Vapor

struct BuilderPruneRequest: Sendable {
    let all: Bool
    let filters: [String: [String]]
    let keepStorage: Int64?
    let reservedSpace: Int64?
    let maxUsedSpace: Int64?
    let minFreeSpace: Int64?
}

struct BuilderPruneResult: Sendable {
    let deletedCaches: [String]
    let spaceReclaimed: Int64
}

struct BuilderCacheRecord: Sendable {
    let id: String
    let parents: [String]
    let kind: String
    let description: String
    let inUse: Bool
    let shared: Bool
    let size: Int64
    let createdAt: String
    let lastUsedAt: String?
    let usageCount: Int
}

protocol ClientBuilderProtocol: Sendable {
    /// Verify the builder is reachable (starting it if necessary).
    /// Pass `qemu: true` when the build requires platforms other than arm64/amd64
    /// (e.g. s390x, ppc64le) so that a QEMU-enabled builder container is used.
    func ensureReachable(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws
    /// Connect to the builder, starting it if necessary.
    /// Pass `qemu: true` when the build requires platforms other than arm64/amd64.
    func connect(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws -> Builder
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord]
}

extension ClientBuilderProtocol {
    // Backward-compatible overloads that default to Rosetta mode (qemu: false).
    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws {
        try await ensureReachable(timeout: timeout, retryInterval: retryInterval, qemu: false, logger: logger)
    }
    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws -> Builder {
        try await connect(timeout: timeout, retryInterval: retryInterval, qemu: false, logger: logger)
    }
}

struct ClientBuilderService: ClientBuilderProtocol {
    private let containerClient = ReconnectingContainerClient(makeClient: { ContainerClient() })
    private let networkClient = ReconnectingContainerClient(makeClient: { NetworkClient() })
    private let builderContainerId: String
    private let builderPort: UInt32
    private let builderCPUs: Int64
    private let builderMemory: String
    private let appSupportURL: URL
    private let containerSystemConfig: ContainerSystemConfig

    init(
        builderContainerId: String = "buildkit",
        builderPort: UInt32 = 8088,
        builderCPUs: Int64 = 2,
        builderMemory: String = "2048MB",
        appSupportURL: URL,
        containerSystemConfig: ContainerSystemConfig
    ) {
        self.builderContainerId = builderContainerId
        self.builderPort = builderPort
        self.builderCPUs = builderCPUs
        self.builderMemory = builderMemory
        self.appSupportURL = appSupportURL
        self.containerSystemConfig = containerSystemConfig
    }

    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        let command = try BuildctlUtility.pruneCommand(from: request)
        var deletedIds: [String] = []
        var reclaimed: Int64 = 0
        var attempted = false
        var succeeded = false
        var lastError: Error?

        // Neither builder is provisioned just to report/reclaim nothing — a fresh install
        // that's never built anything shouldn't have `docker builder prune` spin up a VM only
        // to say "0 bytes freed".
        for qemu in [false, true] {
            let container: ContainerSnapshot?
            do {
                container = try await existingRunningBuilderContainer(qemu: qemu)
            } catch {
                // A lookup failure is itself a real, attempted-but-failed outcome — unlike
                // the container genuinely not running (the ordinary, benign `nil` case
                // below), this must count toward `attempted` or a lookup-only failure on
                // both builders would silently return an empty success.
                attempted = true
                logger.error("buildctl prune\(qemu ? " (qemu)" : "") lookup failed: \(error)")
                lastError = error
                continue
            }
            guard let container else { continue }
            attempted = true
            do {
                let stdoutText = try await execute(command: command, in: container, actionName: "buildctl prune\(qemu ? " (qemu)" : "")", logger: logger)
                let entries = BuildctlUtility.parsePruneOutput(stdoutText, logger: logger)
                deletedIds.append(contentsOf: entries.compactMap(\.id))
                reclaimed += entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                succeeded = true
            } catch {
                // One builder's transient failure shouldn't hide a successful prune of the
                // other — log and keep going instead of propagating and losing everything
                // already accumulated. Only rethrown below if EVERY attempted builder failed.
                logger.error("buildctl prune\(qemu ? " (qemu)" : "") failed: \(error)")
                lastError = error
            }
        }

        // Every builder that was actually running failed — an empty success result here
        // would silently read as "nothing to prune" instead of "the operation failed".
        if attempted, !succeeded, let lastError {
            throw lastError
        }

        return BuilderPruneResult(deletedCaches: deletedIds, spaceReclaimed: reclaimed)
    }

    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        let command = BuildctlUtility.duCommand()
        var records: [BuilderCacheRecord] = []
        var attempted = false
        var succeeded = false
        var lastError: Error?

        for qemu in [false, true] {
            let container: ContainerSnapshot?
            do {
                container = try await existingRunningBuilderContainer(qemu: qemu)
            } catch {
                attempted = true
                logger.error("buildctl du\(qemu ? " (qemu)" : "") lookup failed: \(error)")
                lastError = error
                continue
            }
            guard let container else { continue }
            attempted = true
            do {
                let stdoutText = try await execute(command: command, in: container, actionName: "buildctl du\(qemu ? " (qemu)" : "")", logger: logger)
                records.append(contentsOf: Self.parseDuRecords(from: stdoutText, logger: logger))
                succeeded = true
            } catch {
                logger.error("buildctl du\(qemu ? " (qemu)" : "") failed: \(error)")
                lastError = error
            }
        }

        if attempted, !succeeded, let lastError {
            throw lastError
        }

        return records
    }

    private static func parseDuRecords(from stdoutText: String, logger: Logger) -> [BuilderCacheRecord] {
        BuildctlUtility.parseDuOutput(stdoutText, logger: logger).compactMap { record in
            guard let id = record.id else { return nil }
            return BuilderCacheRecord(
                id: id,
                parents: record.parents ?? [],
                kind: record.recordType ?? "regular",
                description: record.recordDescription ?? "",
                inUse: record.inUse ?? false,
                shared: record.shared ?? false,
                size: record.size ?? 0,
                createdAt: record.createdAt ?? "",
                lastUsedAt: record.lastUsedAt,
                usageCount: record.usageCount ?? 0
            )
        }
    }

    /// Returns the QEMU (or Rosetta) builder container only if it's already running — never
    /// creates/starts it, unlike `runningBuilderContainer`. Used by reporting/cleanup
    /// operations (`prune`/`diskUsage`) that shouldn't provision a builder VM just to say
    /// there's nothing to report for it.
    private func existingRunningBuilderContainer(qemu: Bool) async throws -> ContainerSnapshot? {
        let containerID = resolvedContainerId(qemu: qemu)
        let container: ContainerSnapshot
        do {
            container = try await containerClient.withClient { try await $0.get(id: containerID) }
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
        return container.status == .running ? container : nil
    }

    func ensureReachable(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws {
        _ = try await runningBuilderContainer(qemu: qemu, logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket(qemu: qemu)
                try? socket.close()
                return
            } catch {
                lastError = error
                logger.debug("Builder reachability check failed: \(error)")
            }

            try await Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability")
    }

    func connect(timeout: Duration, retryInterval: Duration, qemu: Bool, logger: Logger) async throws -> Builder {
        _ = try await runningBuilderContainer(qemu: qemu, logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket(qemu: qemu)
                let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                let builder = try await Builder(socket: socket, group: group, logger: logger)
                do {
                    _ = try await builder.info()
                    return builder
                } catch {
                    try? await group.shutdownGracefully()
                    throw error
                }
            } catch {
                lastError = error
                logger.debug("Builder connection attempt failed: \(error)")
            }

            try await Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder")
    }

    private func dialBuilderSocket(qemu: Bool) async throws -> FileHandle {
        let container = try await runningBuilderContainer(qemu: qemu, logger: nil)
        return try await containerClient.withClient { try await $0.dial(id: container.id, port: builderPort) }
    }

    private func runningBuilderContainer(qemu: Bool, logger: Logger?) async throws -> ContainerSnapshot {
        let containerID = resolvedContainerId(qemu: qemu)
        let container: ContainerSnapshot
        do {
            container = try await containerClient.withClient { try await $0.get(id: containerID) }
        } catch let error as ContainerizationError where error.code == .notFound {
            logger?.info("Builder container not found, creating a new builder instance")
            do {
                return try await createAndStartBuilder(qemu: qemu, logger: logger)
            } catch {
                // A concurrent caller may have created it between our own `get` miss and this
                // `create` call — this codebase's own split-build (see BuildRoute) can now
                // issue genuinely concurrent build requests, some of which may need the same
                // cold-started builder. If someone else won the race, use what they created
                // instead of failing this request; if `get` also fails, this wasn't a race —
                // propagate the original creation error. Routed through the same status
                // handling below (not returned directly) — the race winner's container could
                // still be `.stopped`/`.stopping` at the exact moment we observe it.
                guard let existing = try? await containerClient.withClient({ try await $0.get(id: containerID) }) else {
                    throw error
                }
                return try await ensureRunning(existing, qemu: qemu, logger: logger)
            }
        }

        return try await ensureRunning(container, qemu: qemu, logger: logger)
    }

    private func ensureRunning(_ container: ContainerSnapshot, qemu: Bool, logger: Logger?) async throws -> ContainerSnapshot {
        let containerID = resolvedContainerId(qemu: qemu)
        guard container.status == .running else {
            switch container.status {
            case .running:
                return container
            case .stopped:
                logger?.info("Builder container is stopped, starting it")
                try await startBuildKit(containerId: container.id)
                return try await containerClient.withClient { try await $0.get(id: container.id) }
            case .stopping:
                throw ContainerizationError(.invalidState, message: "BuildKit container '\(containerID)' is stopping")
            case .unknown:
                logger?.warning("Builder container has unknown state, recreating it")
                try? await containerClient.withClient { try await $0.delete(id: container.id) }
                return try await createAndStartBuilder(qemu: qemu, logger: logger)
            @unknown default:
                throw ContainerizationError(.invalidState, message: "BuildKit container '\(containerID)' is in an unsupported state")
            }
        }

        return container
    }

    /// Returns the container ID for a given mode.
    /// QEMU-mode builder uses a distinct ID (base ID + "-qemu") so both builders can
    /// coexist and be looked up independently.
    private func resolvedContainerId(qemu: Bool) -> String {
        qemu ? "\(builderContainerId)-qemu" : builderContainerId
    }

    private func createAndStartBuilder(qemu: Bool, logger: Logger?) async throws -> ContainerSnapshot {
        let containerID = resolvedContainerId(qemu: qemu)
        let exportsMount = appSupportURL.appendingPathComponent("builder")
        if !FileManager.default.fileExists(atPath: exportsMount.path) {
            try FileManager.default.createDirectory(at: exportsMount, withIntermediateDirectories: true)
        }

        let builderImage = containerSystemConfig.build.image
        let builderPlatform = Platform(arch: "arm64", os: "linux", variant: "v8")
        // QEMU mode: register binfmt handlers inside the VM kernel for all foreign
        // architectures (s390x, ppc64le, riscv64, etc.).  Rosetta is disabled because
        // it and QEMU binfmt registration are mutually exclusive in the builder shim.
        let useRosetta = qemu ? false : containerSystemConfig.build.rosetta

        let image = try await ClientImage.fetch(reference: builderImage, platform: builderPlatform, containerSystemConfig: containerSystemConfig)
        _ = try await image.getCreateSnapshot(platform: builderPlatform)
        let imageDesc = ImageDescription(reference: builderImage, descriptor: image.descriptor)

        let imageConfig = try await image.config(for: builderPlatform).config
        guard let defaultNetwork = try await networkClient.withClient({ try await $0.builtin }) else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        let nameserver = IPv4Address(defaultNetwork.status.ipv4Subnet.lower.value + 1).description

        let config = try Self.builderContainerConfiguration(
            builderContainerId: containerID,
            imageDescription: imageDesc,
            imageEnv: imageConfig?.env,
            useRosetta: useRosetta,
            qemu: qemu,
            builderCPUs: builderCPUs,
            builderMemory: builderMemory,
            exportsMountPath: exportsMount.path,
            networkId: defaultNetwork.id,
            nameserver: nameserver
        )

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        try await containerClient.withClient { try await $0.create(configuration: config, options: .default, kernel: kernel) }
        try await startBuildKit(containerId: containerID)
        return try await containerClient.withClient { try await $0.get(id: containerID) }
    }

    /// Pure construction of the BuildKit guest's ContainerConfiguration — no real service
    /// calls, so it's directly unit-testable without a live daemon. Kept separate from
    /// `createAndStartBuilder` (which resolves the image/network inputs this needs).
    static func builderContainerConfiguration(
        builderContainerId: String,
        imageDescription: ImageDescription,
        imageEnv: [String]?,
        useRosetta: Bool,
        qemu: Bool,
        builderCPUs: Int64,
        builderMemory: String,
        exportsMountPath: String,
        networkId: String,
        nameserver: String
    ) throws -> ContainerConfiguration {
        let processConfig = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            // `--enable-qemu` depends solely on which builder instance this is — NOT on
            // `useRosetta`, which independently reflects the user's own rosetta config and
            // can be false even for the non-qemu builder (e.g. `build.rosetta` disabled).
            // Deriving it from `!useRosetta` would register QEMU binfmt handlers on the
            // Rosetta builder too in that case, which this type's own doc comment says are
            // mutually exclusive in the shim.
            arguments: ["--debug", "--vsock", qemu ? "--enable-qemu" : nil].compactMap { $0 },
            environment: imageEnv ?? [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: builderContainerId, image: imageDescription, process: processConfig)
        config.resources = try Parser.resources(cpus: builderCPUs, memory: builderMemory, defaultCPUs: BuildConfig.defaultCPUs, defaultMemory: BuildConfig.defaultMemory)
        config.labels = [ResourceLabelKeys.role: ResourceRoleValues.builder]
        config.mounts = [
            Filesystem.tmpfs(destination: "/run", options: []),
            Filesystem.virtiofs(source: exportsMountPath, destination: "/var/lib/container-builder-shim/exports", options: []),
        ]
        // BuildKit's runc-native snapshotter rbind-mounts a snapshot to read the build
        // context/Dockerfile, which needs CAP_SYS_ADMIN — root alone doesn't grant it.
        // Matches apple/container's own builder bootstrap (BuilderStart.swift).
        config.capAdd = ["ALL"]
        config.rosetta = useRosetta
        config.networks = [
            AttachmentConfiguration(network: networkId, options: AttachmentOptions(hostname: builderContainerId))
        ]
        config.dns = ContainerConfiguration.DNSConfiguration(nameservers: [nameserver], domain: nil, searchDomains: [], options: [])
        return config
    }

    private func startBuildKit(containerId: String) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }

        do {
            let process = try await containerClient.withClient { try await $0.bootstrap(id: containerId, stdio: io.stdio) }
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? await containerClient.withClient { try await $0.stop(id: containerId) }
            try? await containerClient.withClient { try await $0.delete(id: containerId) }
            if let containerizationError = error as? ContainerizationError {
                throw containerizationError
            }
            throw ContainerizationError(.internalError, message: "failed to start BuildKit: \(error)")
        }
    }

    private func execute(command: BuildctlUtility.Command, in container: ContainerSnapshot, actionName: String, logger: Logger) async throws -> String {
        var processConfig = container.configuration.initProcess
        processConfig.executable = command.executable
        processConfig.arguments = command.arguments
        processConfig.terminal = false

        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw ContainerizationError(.internalError, message: "Failed to create I/O pipes")
        }
        let process: ClientProcess
        let processConfigToSend = processConfig
        do {
            process = try await containerClient.withClient {
                try await $0.createProcess(
                    containerId: container.id,
                    processId: UUID().uuidString.lowercased(),
                    configuration: processConfigToSend,
                    stdio: pipes.stdioArray
                )
            }
        } catch {
            pipes.closeAll()
            throw error
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw error
        }
        let (exitCode, stdoutData, stderrData) = try await pipes.collectOutput {
            try await process.wait()
        }
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderrText.isEmpty {
            logger.error("\(actionName) stderr:\n\(stderrText)")
        }

        guard exitCode == 0 else {
            let details = stderrText.isEmpty ? stdoutText : stderrText
            throw ContainerizationError(.unknown, message: "\(actionName) failed with exit code \(exitCode): \(details)")
        }

        return stdoutText
    }

}
