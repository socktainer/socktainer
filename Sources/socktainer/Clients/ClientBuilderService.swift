import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import CryptoKit
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
    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws
    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws
        -> any BuilderBuildSession
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord]
}

protocol BuilderBuildSession: Sendable {
    func build(_ configuration: Builder.BuildConfig) async throws
    func close() async
}

private actor BuilderBuildSessionCloseState {
    private var closed = false

    func close(
        socket: FileHandle,
        group: MultiThreadedEventLoopGroup
    ) async {
        guard !closed else { return }
        closed = true
        try? socket.close()
        try? await group.shutdownGracefully()
    }
}

private struct LiveBuilderBuildSession: BuilderBuildSession {
    let builder: Builder
    let socket: FileHandle
    let group: MultiThreadedEventLoopGroup
    private let closeState = BuilderBuildSessionCloseState()

    func build(_ configuration: Builder.BuildConfig) async throws {
        try await builder.build(configuration)
    }

    func close() async {
        await closeState.close(socket: socket, group: group)
    }
}

enum BuilderSessionLifecycle {
    static func withSession<Result: Sendable>(
        _ session: any BuilderBuildSession,
        operation: @Sendable (any BuilderBuildSession) async throws -> Result
    ) async throws -> Result {
        let lifetime = BuilderSessionLifetime(session: session)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let result = try await operation(session)
                await lifetime.close()
                return result
            } catch {
                await lifetime.close()
                throw error
            }
        } onCancel: {
            // Closing the transport is what interrupts a BuildKit RPC that is
            // blocked below Swift's cooperative-cancellation boundary. The
            // shared lifetime makes this race exactly-once and lets the main
            // operation await the same close before it unwinds.
            Task { await lifetime.close() }
        }
    }
}

private actor BuilderSessionLifetime {
    private let session: any BuilderBuildSession
    private var closeTask: Task<Void, Never>?

    init(session: any BuilderBuildSession) {
        self.session = session
    }

    func close() async {
        if let closeTask {
            await closeTask.value
            return
        }

        let session = self.session
        let closeTask = Task { await session.close() }
        self.closeTask = closeTask
        await closeTask.value
    }
}

/// Narrow identity boundary used by the internal BuildKit container. Keeping
/// the resolver's mutation coordinator on the same object makes it impossible
/// to accidentally resolve with one store epoch and lease with another.
protocol BuilderImageIdentityResolving: Sendable {
    var mutationCoordinator: ImageMutationCoordinator { get }
    func resolve(_ reference: String) async throws -> ResolvedImageIdentity
    func resolveDuringMutation(_ reference: String) async throws
        -> ResolvedImageIdentity
    func invalidate() async
}

struct LiveBuilderImageIdentityResolver: BuilderImageIdentityResolving {
    let resolver: ImageIdentityResolver

    var mutationCoordinator: ImageMutationCoordinator {
        resolver.mutationCoordinator
    }

    func resolve(_ reference: String) async throws -> ResolvedImageIdentity {
        try await resolver.resolve(reference)
    }

    func resolveDuringMutation(_ reference: String) async throws
        -> ResolvedImageIdentity
    {
        try await resolver.resolveDuringMutation(reference)
    }

    func invalidate() async {
        await resolver.invalidate()
    }
}

/// Container API seam for the builder lifecycle. The production adapter keeps
/// the existing stale-XPC reconnection behavior while allowing lifecycle races
/// and commit-then-XPC-error paths to be exercised without a live daemon.
protocol BuilderContainerRuntime: NativeContainerCreating {
    func stop(id: String) async throws
    func delete(id: String, force: Bool) async throws
    func bootstrap(id: String, stdio: [FileHandle?]) async throws -> ClientProcess
    func dial(id: String, port: UInt32) async throws -> FileHandle
    func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess
}

struct LiveBuilderContainerRuntime: BuilderContainerRuntime {
    private let client = ReconnectingContainerClient(
        makeClient: { ContainerClient() }
    )

    func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        kernel: Kernel
    ) async throws {
        try await client.withClient {
            try await $0.create(
                configuration: configuration,
                options: options,
                kernel: kernel
            )
        }
    }

    func get(id: String) async throws -> ContainerSnapshot {
        try await client.withClient { try await $0.get(id: id) }
    }

    func stop(id: String) async throws {
        try await client.withClient { try await $0.stop(id: id) }
    }

    func delete(id: String, force: Bool) async throws {
        try await client.withClient {
            try await $0.delete(id: id, force: force)
        }
    }

    func bootstrap(
        id: String,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        try await client.withClient {
            try await $0.bootstrap(id: id, stdio: stdio)
        }
    }

    func dial(id: String, port: UInt32) async throws -> FileHandle {
        try await client.withClient {
            try await $0.dial(id: id, port: port)
        }
    }

    func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        try await client.withClient {
            try await $0.createProcess(
                containerId: containerId,
                processId: processId,
                configuration: configuration,
                stdio: stdio
            )
        }
    }
}

protocol BuilderNetworkProviding: Sendable {
    func builtin() async throws -> NetworkResource?
}

struct LiveBuilderNetworkProvider: BuilderNetworkProviding {
    private let client = ReconnectingContainerClient(
        makeClient: { NetworkClient() }
    )

    func builtin() async throws -> NetworkResource? {
        try await client.withClient { try await $0.builtin }
    }
}

protocol BuilderKernelProviding: Sendable {
    func defaultKernel() async throws -> Kernel
}

struct LiveBuilderKernelProvider: BuilderKernelProviding {
    func defaultKernel() async throws -> Kernel {
        try await ClientKernel.getDefaultKernel(for: .current)
    }
}

/// Coalesces every concurrent build/prune/du caller onto one builder lifecycle
/// operation. An unstructured task deliberately outlives cancellation of an
/// individual HTTP request once native container creation may have committed.
actor BuilderLifecycleCoordinator {
    private var active: (id: UUID, task: Task<ContainerSnapshot, any Error>)?

    func run(
        _ operation: @Sendable @escaping () async throws -> ContainerSnapshot
    ) async throws -> ContainerSnapshot {
        if let active {
            return try await active.task.value
        }

        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await operation() }
        active = (id, task)
        do {
            let result = try await task.value
            clear(id: id)
            return result
        } catch {
            clear(id: id)
            throw error
        }
    }

    private func clear(id: UUID) {
        guard active?.id == id else { return }
        active = nil
    }
}

struct ClientBuilderService: ClientBuilderProtocol {
    static let specificationLabel = "com.socktainer.builder.specification"
    static let specificationVersion = 1

    private let builderContainerId: String
    private let builderPort: UInt32
    private let builderCPUs: Int64
    private let builderMemory: String
    private let appSupportURL: URL
    private let containerSystemConfig: ContainerSystemConfig
    private let imageResolver: any BuilderImageIdentityResolving
    private let imageClient: any ClientImageProtocol
    private let imageMutationCoordinator: ImageMutationCoordinator
    private let imageLeaseManager: any ContainerImageLeasing
    private let imageLeaseReservations: ContainerImageLeaseReservationRegistry
    private let imageLeaseReconciler: any ContainerImageLeaseReconciling
    private let runnableImageSelector: RunnableImageSelector
    private let snapshotProvider: any RunnableImageSnapshotProviding
    private let rootFSMaterializer: ContainerRootFSMaterializer
    private let containerRuntime: any BuilderContainerRuntime
    private let networkProvider: any BuilderNetworkProviding
    private let kernelProvider: any BuilderKernelProviding
    private let lifecycleCoordinator: BuilderLifecycleCoordinator
    private let existingBuilderHealthTimeout: Duration

    init(
        builderContainerId: String = "buildkit",
        builderPort: UInt32 = 8088,
        builderCPUs: Int64 = 2,
        builderMemory: String = "2048MB",
        appSupportURL: URL,
        containerSystemConfig: ContainerSystemConfig,
        imageResolver: any BuilderImageIdentityResolving,
        imageClient: any ClientImageProtocol,
        imageMutationCoordinator: ImageMutationCoordinator,
        imageLeaseManager: any ContainerImageLeasing =
            LiveContainerImageLeaseManager(),
        imageLeaseReservations: ContainerImageLeaseReservationRegistry =
            .shared,
        imageLeaseReconciler: any ContainerImageLeaseReconciling,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector(),
        snapshotProvider: (any RunnableImageSnapshotProviding)? = nil,
        rootFSMaterializer: ContainerRootFSMaterializer? = nil,
        containerRuntime: any BuilderContainerRuntime =
            LiveBuilderContainerRuntime(),
        networkProvider: any BuilderNetworkProviding =
            LiveBuilderNetworkProvider(),
        kernelProvider: any BuilderKernelProviding =
            LiveBuilderKernelProvider(),
        lifecycleCoordinator: BuilderLifecycleCoordinator =
            BuilderLifecycleCoordinator(),
        existingBuilderHealthTimeout: Duration = .seconds(3)
    ) {
        precondition(
            imageResolver.mutationCoordinator === imageMutationCoordinator,
            "builder resolver and image service must share one mutation coordinator"
        )
        self.builderContainerId = builderContainerId
        self.builderPort = builderPort
        self.builderCPUs = builderCPUs
        self.builderMemory = builderMemory
        self.appSupportURL = appSupportURL
        self.containerSystemConfig = containerSystemConfig
        self.imageResolver = imageResolver
        self.imageClient = imageClient
        self.imageMutationCoordinator = imageMutationCoordinator
        self.imageLeaseManager = imageLeaseManager
        self.imageLeaseReservations = imageLeaseReservations
        self.imageLeaseReconciler = imageLeaseReconciler
        self.runnableImageSelector = runnableImageSelector
        self.snapshotProvider =
            snapshotProvider
            ?? LiveRunnableImageSnapshotProvider(appSupportURL: appSupportURL)
        self.rootFSMaterializer =
            rootFSMaterializer
            ?? ContainerRootFSMaterializer(appSupportURL: appSupportURL)
        self.containerRuntime = containerRuntime
        self.networkProvider = networkProvider
        self.kernelProvider = kernelProvider
        self.lifecycleCoordinator = lifecycleCoordinator
        self.existingBuilderHealthTimeout = existingBuilderHealthTimeout
    }

    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        let container = try await runningBuilderContainer(logger: logger)

        let command = try BuildctlUtility.pruneCommand(from: request)
        let stdoutText = try await execute(command: command, in: container, actionName: "buildctl prune", logger: logger)

        let entries = BuildctlUtility.parsePruneOutput(stdoutText, logger: logger)
        let deletedIds = entries.compactMap(\.id)
        let reclaimed = entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        return BuilderPruneResult(deletedCaches: deletedIds, spaceReclaimed: reclaimed)
    }

    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        let container = try await runningBuilderContainer(logger: logger)
        let command = BuildctlUtility.duCommand()
        let stdoutText = try await execute(command: command, in: container, actionName: "buildctl du", logger: logger)

        return BuildctlUtility.parseDuOutput(stdoutText, logger: logger).compactMap { record in
            guard let id = record.id else {
                return nil
            }
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

    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws {
        _ = try await runningBuilderContainer(
            logger: logger,
            readinessTimeout: timeout,
            retryInterval: retryInterval
        )
    }

    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws
        -> any BuilderBuildSession
    {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                _ = try await runningBuilderContainer(
                    logger: logger,
                    readinessTimeout: timeout,
                    retryInterval: retryInterval
                )
                let socket = try await dialBuilderSocket()
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                let builder: Builder
                do {
                    builder = try await Builder(
                        socket: socket,
                        group: group,
                        logger: logger
                    )
                } catch {
                    try? socket.close()
                    try? await group.shutdownGracefully()
                    throw error
                }
                let session = LiveBuilderBuildSession(
                    builder: builder,
                    socket: socket,
                    group: group
                )
                do {
                    _ = try await builder.info()
                    return session
                } catch {
                    await session.close()
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

    private func dialBuilderSocket() async throws -> FileHandle {
        try await containerRuntime.dial(
            id: builderContainerId,
            port: builderPort
        )
    }

    func runningBuilderContainer(
        logger: Logger?,
        readinessTimeout: Duration = .seconds(30),
        retryInterval: Duration = .milliseconds(250)
    ) async throws
        -> ContainerSnapshot
    {
        try await lifecycleCoordinator.run { [self] in
            try await reconcileBuilderContainer(
                logger: logger,
                readinessTimeout: readinessTimeout,
                retryInterval: retryInterval
            )
        }
    }

    private func reconcileBuilderContainer(
        logger: Logger?,
        readinessTimeout: Duration,
        retryInterval: Duration
    ) async throws -> ContainerSnapshot {
        let operationLogger =
            logger ?? Logger(label: "socktainer.builder-lifecycle")
        let exportsMount = appSupportURL.appendingPathComponent("builder")
        if !FileManager.default.fileExists(atPath: exportsMount.path) {
            try FileManager.default.createDirectory(
                at: exportsMount,
                withIntermediateDirectories: true
            )
        }

        let builderImage = containerSystemConfig.build.image
        let builderPlatform = Platform(arch: "arm64", os: "linux", variant: "v8")
        let useRosetta = containerSystemConfig.build.rosetta

        // Pull only when canonical identity lookup proves the configured image
        // is absent. The stream is fully drained: pull/import commit and tag
        // reconciliation may occur after the last progress message is produced.
        _ = try await Self.resolveOrPull(
            reference: builderImage,
            platform: builderPlatform,
            resolve: { try await imageResolver.resolve(builderImage) },
            pull: { platform in
                try await imageClient.pull(
                    image: builderImage,
                    tag: nil,
                    platform: platform,
                    fallbackPolicy:
                        useRosetta ? .allowRosetta : .strict,
                    logger: operationLogger
                )
            }
        )

        // Re-resolve and acquire the immutable hidden reference in the same
        // mutation epoch. Reserve it before releasing the writer so image prune
        // cannot observe the builder-create pipeline as ownerless.
        let reserved = try await imageMutationCoordinator.performMutation {
            let resolved = try await imageResolver.resolveDuringMutation(
                builderImage
            )
            let lease = try await imageLeaseManager.acquire(for: resolved)
            let reservation = await imageLeaseReservations.reserve(lease)
            await imageResolver.invalidate()
            return (lease: lease, reservation: reservation)
        }
        let imageLease = reserved.lease
        let reservation = reserved.reservation
        let leaseConvergence = ContainerCreateLeaseConvergence(
            rootDescriptor: imageLease.image.descriptor,
            reservation: reservation,
            reconciler: imageLeaseReconciler
        )
        defer {
            Task.detached(priority: .utility) {
                await leaseConvergence.converge()
            }
        }

        let selection =
            try await imageMutationCoordinator
            .withMutationExcluded {
                let descriptors = try await runnableImageSelector.descriptors(
                    for: imageLease.image
                )
                guard
                    let variant = runnableImageSelector.selectVariant(
                        from: descriptors,
                        requestedPlatform: builderPlatform
                    )
                else {
                    throw ContainerizationError(
                        .unsupported,
                        message:
                            "builder image \(builderImage) does not contain platform \(builderPlatform.description)"
                    )
                }
                return (descriptors: descriptors, variant: variant)
            }

        guard let defaultNetwork = try await networkProvider.builtin() else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        let nameserver = IPv4Address(defaultNetwork.status.ipv4Subnet.lower.value + 1).description

        var config = try Self.builderContainerConfiguration(
            builderContainerId: builderContainerId,
            imageDescription: imageLease.image.description,
            imageEnv: selection.variant.config.config?.env,
            useRosetta: useRosetta,
            builderCPUs: builderCPUs,
            builderMemory: builderMemory,
            exportsMountPath: exportsMount.path,
            networkId: defaultNetwork.id,
            nameserver: nameserver
        )
        config.labels[Self.specificationLabel] =
            try Self
            .builderSpecificationFingerprint(configuration: config)

        if let existing = try await existingBuilderContainer() {
            if Self.isCompatibleBuilder(existing, desired: config) {
                switch existing.status {
                case .running:
                    do {
                        try await waitForBuilderReachability(
                            timeout: min(
                                readinessTimeout,
                                existingBuilderHealthTimeout
                            ),
                            retryInterval: retryInterval,
                            logger: operationLogger
                        )
                        await leaseConvergence.converge()
                        return existing
                    } catch {
                        operationLogger.warning(
                            "Compatible builder process is unreachable; recreating it: \(error)"
                        )
                        try await destroyBuilder(
                            existing,
                            logger: operationLogger
                        )
                    }
                case .stopped:
                    operationLogger.info(
                        "Builder container is stopped, starting it"
                    )
                    do {
                        try await startBuildKit(container: existing)
                        let running = try await containerRuntime.get(
                            id: existing.id
                        )
                        try await waitForBuilderReachability(
                            timeout: readinessTimeout,
                            retryInterval: retryInterval,
                            logger: operationLogger
                        )
                        await leaseConvergence.converge()
                        return running
                    } catch {
                        operationLogger.warning(
                            "Failed to restart the compatible builder; recreating it: \(error)"
                        )
                        try await destroyBuilder(
                            existing,
                            logger: operationLogger
                        )
                    }
                case .stopping, .unknown:
                    operationLogger.warning(
                        "Builder container is \(existing.status); recreating it"
                    )
                    try await destroyBuilder(existing, logger: operationLogger)
                @unknown default:
                    throw ContainerizationError(
                        .invalidState,
                        message:
                            "BuildKit container '\(builderContainerId)' is in an unsupported state"
                    )
                }
            } else {
                operationLogger.info(
                    "Builder image or configuration changed; recreating the internal BuildKit container"
                )
                try await destroyBuilder(existing, logger: operationLogger)
            }
        } else {
            operationLogger.info(
                "Builder container not found, creating a new builder instance"
            )
        }

        let preparedImage =
            try await imageMutationCoordinator
            .withMutationExcluded {
                try await snapshotProvider.snapshot(
                    for: imageLease.image,
                    variant: selection.variant,
                    descriptors: selection.descriptors,
                    logger: operationLogger
                )
            }
        defer { preparedImage.cleanup() }

        let recoveredStagingBundles =
            await rootFSMaterializer
            .recoverStalePrivateStagingBundles(
                reservationRegistry: imageLeaseReservations
            )
        if recoveredStagingBundles > 0 {
            operationLogger.warning(
                "Recovered \(recoveredStagingBundles) stale private rootfs staging bundle(s)"
            )
        }

        let preparedRootFS: PreparedContainerRootFS
        do {
            preparedRootFS = try rootFSMaterializer.materialize(
                snapshot: preparedImage.filesystem,
                containerID: builderContainerId,
                readOnly: config.readOnly,
                reservation: reservation
            )
        } catch ContainerRootFSMaterializationError.containerBundleExists {
            let recovered =
                await ContainerCreateRoute
                .recoverStalePreCreateBundle(
                    containerID: builderContainerId,
                    expectedConfiguration: config,
                    rootFSMaterializer: rootFSMaterializer,
                    reservationRegistry: imageLeaseReservations,
                    nativeContainerCreator: containerRuntime,
                    logger: operationLogger
                )
            guard recovered else {
                throw ContainerizationError(
                    .exists,
                    message:
                        "builder container bundle '\(builderContainerId)' already exists"
                )
            }
            preparedRootFS = try rootFSMaterializer.materialize(
                snapshot: preparedImage.filesystem,
                containerID: builderContainerId,
                readOnly: config.readOnly,
                reservation: reservation
            )
        }

        let kernel = try await kernelProvider.defaultKernel()
        let options = ContainerCreateOptions(
            autoRemove: false,
            rootFsOverride: preparedRootFS.filesystem
        )
        let committer = NativeContainerCreateCommitter(
            client: containerRuntime,
            mutationCoordinator: imageMutationCoordinator,
            leaseManager: imageLeaseManager
        )
        let created: ContainerSnapshot
        switch await committer.commit(
            configuration: config,
            options: options,
            kernel: kernel,
            lease: imageLease
        ) {
        case .committed(let snapshot):
            preparedRootFS.markCommitted()
            await leaseConvergence.converge()
            created = snapshot
        case .definitivelyFailed(let error):
            preparedRootFS.rollback()
            await leaseConvergence.converge()
            throw error
        case .conflicting(let snapshot, let error):
            preparedRootFS.markCommitted()
            operationLogger.error(
                "Builder create returned \(error), and ID \(snapshot.id) belongs to a different native configuration"
            )
            await leaseConvergence.converge()
            throw ContainerizationError(
                .exists,
                message: "builder container ID '\(builderContainerId)' is in use"
            )
        case .indeterminate(let error):
            await leaseConvergence.handOff()
            Task.detached(priority: .utility) {
                await ContainerCreateRoute.settleIndeterminateCreate(
                    expected: config,
                    options: options,
                    kernel: kernel,
                    lease: imageLease,
                    preparedRootFS: preparedRootFS,
                    rootDescriptor: imageLease.image.descriptor,
                    reservation: reservation,
                    committer: committer,
                    leaseReconciler: imageLeaseReconciler,
                    logger: operationLogger
                )
            }
            throw ContainerizationError(
                .internalError,
                message: "failed to confirm builder container creation",
                cause: error
            )
        }

        do {
            try await startBuildKit(container: created)
            try await waitForBuilderReachability(
                timeout: readinessTimeout,
                retryInterval: retryInterval,
                logger: operationLogger
            )
            return try await containerRuntime.get(id: builderContainerId)
        } catch {
            operationLogger.warning(
                "New builder failed to become reachable; removing it: \(error)"
            )
            try? await destroyBuilder(created, logger: operationLogger)
            throw error
        }
    }

    private func waitForBuilderReachability(
        timeout: Duration,
        retryInterval: Duration,
        logger: Logger
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        repeat {
            try Task.checkCancellation()
            do {
                let socket = try await dialBuilderSocket()
                try? socket.close()
                return
            } catch {
                lastError = error
                logger.debug("Builder reachability check failed: \(error)")
            }
            guard clock.now < deadline else { break }
            try await Task.sleep(for: retryInterval)
        } while clock.now < deadline

        if let lastError {
            throw ContainerizationError(
                .timeout,
                message: "Timeout waiting for builder reachability: \(lastError)"
            )
        }
        throw ContainerizationError(
            .timeout,
            message: "Timeout waiting for builder reachability"
        )
    }

    private func existingBuilderContainer() async throws
        -> ContainerSnapshot?
    {
        do {
            return try await containerRuntime.get(id: builderContainerId)
        } catch let error as ContainerizationError
            where NativeContainerCreateCommitter.isNotFound(error)
        {
            return nil
        }
    }

    static func resolveOrPull(
        reference: String,
        platform: Platform,
        resolve: @Sendable () async throws -> ResolvedImageIdentity,
        pull:
            @Sendable (Platform) async throws -> AsyncThrowingStream<
                PullProgress, any Error
            >
    ) async throws -> ResolvedImageIdentity {
        do {
            return try await resolve()
        } catch ImageIdentityResolutionError.notFound {
            let progress = try await pull(platform)
            for try await _ in progress {}
            return try await resolve()
        }
    }

    static func builderSpecificationFingerprint(
        configuration: ContainerConfiguration
    ) throws -> String {
        var stable = configuration
        stable.labels.removeValue(forKey: specificationLabel)
        // Creation time is request metadata, not part of builder compatibility.
        stable.creationDate = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = Data("v\(specificationVersion)\u{0}".utf8)
        bytes.append(try encoder.encode(stable))
        return SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func isCompatibleBuilder(
        _ existing: ContainerSnapshot,
        desired: ContainerConfiguration
    ) -> Bool {
        guard
            existing.configuration.labels[specificationLabel]
                == desired.labels[specificationLabel]
        else {
            return false
        }
        return existing.configuration.image.reference
            == desired.image.reference
            && existing.configuration.image.descriptor
                == desired.image.descriptor
    }

    /// Pure construction of the BuildKit guest's ContainerConfiguration — no real service
    /// calls, so it's directly unit-testable without a live daemon. Kept separate from
    /// `createAndStartBuilder` (which resolves the image/network inputs this needs).
    static func builderContainerConfiguration(
        builderContainerId: String,
        imageDescription: ImageDescription,
        imageEnv: [String]?,
        useRosetta: Bool,
        builderCPUs: Int64,
        builderMemory: String,
        exportsMountPath: String,
        networkId: String,
        nameserver: String
    ) throws -> ContainerConfiguration {
        let processConfig = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            arguments: ["--debug", "--vsock", useRosetta ? nil : "--enable-qemu"].compactMap { $0 },
            environment: imageEnv ?? [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: builderContainerId, image: imageDescription, process: processConfig)
        config.resources = try Parser.resources(cpus: builderCPUs, memory: builderMemory, defaultCPUs: BuildConfig.defaultCPUs, defaultMemory: BuildConfig.defaultMemory)
        config.labels = [
            ResourceLabelKeys.plugin: "builder",
            ResourceLabelKeys.role: ResourceRoleValues.builder,
        ]
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

    private func startBuildKit(container: ContainerSnapshot) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }

        do {
            let process = try await containerRuntime.bootstrap(
                id: container.id,
                stdio: io.stdio
            )
            try await process.start()
            try io.closeAfterStart()
        } catch {
            if let containerizationError = error as? ContainerizationError {
                throw containerizationError
            }
            throw ContainerizationError(.internalError, message: "failed to start BuildKit: \(error)")
        }
    }

    private func destroyBuilder(
        _ container: ContainerSnapshot,
        logger: Logger
    ) async throws {
        if container.status == .running || container.status == .stopping {
            do {
                try await containerRuntime.stop(id: container.id)
            } catch {
                logger.warning(
                    "Failed to stop stale builder \(container.id) before forced deletion: \(error)"
                )
            }
        }
        try await containerRuntime.delete(id: container.id, force: true)
        await imageLeaseReconciler.reconcile(
            rootDescriptor: container.configuration.image.descriptor
        )
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
            process = try await containerRuntime.createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfigToSend,
                stdio: pipes.stdioArray
            )
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
