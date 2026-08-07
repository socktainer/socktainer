import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Testing

@testable import socktainer

private enum BuilderHarnessError: Error, Equatable {
    case pullFailed
    case unsupportedOperation
}

private actor BuilderHarnessResolver: BuilderImageIdentityResolving {
    nonisolated let mutationCoordinator: ImageMutationCoordinator
    private let identity: ResolvedImageIdentity
    private var available: Bool

    init(
        identity: ResolvedImageIdentity,
        available: Bool,
        mutationCoordinator: ImageMutationCoordinator
    ) {
        self.identity = identity
        self.available = available
        self.mutationCoordinator = mutationCoordinator
    }

    func resolve(_ reference: String) async throws -> ResolvedImageIdentity {
        try resolved(reference)
    }

    func resolveDuringMutation(_ reference: String) async throws
        -> ResolvedImageIdentity
    {
        try resolved(reference)
    }

    func invalidate() async {}

    func makeAvailable() {
        available = true
    }

    private func resolved(_ reference: String) throws
        -> ResolvedImageIdentity
    {
        guard available else {
            throw ImageIdentityResolutionError.notFound(reference)
        }
        return identity
    }
}

private actor BuilderHarnessImageClient: ClientImageProtocol {
    enum PullBehavior: Sendable {
        case succeed
        case fail
        case cancel
    }

    private let image: ClientImage
    private var behavior: PullBehavior
    private(set) var pullCalls = 0

    init(image: ClientImage, behavior: PullBehavior = .succeed) {
        self.image = image
        self.behavior = behavior
    }

    func setPullBehavior(_ behavior: PullBehavior) {
        self.behavior = behavior
    }

    func list(includeSystemImages: Bool) async throws -> [ClientImage] {
        [image]
    }

    func delete(id: String) async throws -> ImageDeletionResult {
        throw BuilderHarnessError.unsupportedOperation
    }

    func pull(
        image: String,
        tag: String?,
        platform: Platform,
        fallbackPolicy: PlatformFallbackPolicy,
        logger: Logger
    ) async throws -> AsyncThrowingStream<PullProgress, Error> {
        pullCalls += 1
        let behavior = behavior
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .succeed:
                continuation.yield(.message("pulled"))
                continuation.finish()
            case .fail:
                continuation.finish(throwing: BuilderHarnessError.pullFailed)
            case .cancel:
                continuation.finish(throwing: CancellationError())
            }
        }
    }

    func push(
        reference: String,
        platform: Platform?,
        logger: Logger
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw BuilderHarnessError.unsupportedOperation
    }

    func prune(
        filters: [String: [String]],
        logger: Logger
    ) async throws -> (
        results: [ImageDeletionResult], spaceReclaimed: Int64
    ) {
        throw BuilderHarnessError.unsupportedOperation
    }

    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> [String] {
        throw BuilderHarnessError.unsupportedOperation
    }

    func save(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> URL {
        throw BuilderHarnessError.unsupportedOperation
    }

    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        throw BuilderHarnessError.unsupportedOperation
    }
}

private actor BuilderHarnessLeaseManager: ContainerImageLeasing {
    let lease: ContainerImageLease
    private(set) var acquireCalls = 0
    private(set) var verifyCalls = 0
    private(set) var releaseCalls = 0

    init(lease: ContainerImageLease) {
        self.lease = lease
    }

    func acquire(for resolved: ResolvedImageIdentity) async throws
        -> ContainerImageLease
    {
        acquireCalls += 1
        return lease
    }

    func verify(_ lease: ContainerImageLease) async throws {
        verifyCalls += 1
        guard lease.reference == self.lease.reference,
            lease.rootDigest == self.lease.rootDigest
        else {
            throw ContainerImageLeaseError.corruptLease(
                reference: lease.reference,
                expected: self.lease.rootDigest,
                actual: lease.rootDigest
            )
        }
    }

    func release(_ lease: ContainerImageLease) async throws {
        releaseCalls += 1
    }
}

private actor BuilderHarnessLeaseReconciler:
    ContainerImageLeaseReconciling
{
    struct Call: Sendable {
        let digest: String
        let reservationID: UUID?
    }

    private let registry: ContainerImageLeaseReservationRegistry
    private(set) var calls: [Call] = []

    init(registry: ContainerImageLeaseReservationRegistry) {
        self.registry = registry
    }

    func reconcile(
        rootDescriptor: Descriptor,
        releasing reservation: ContainerImageLeaseReservation?
    ) async {
        calls.append(
            Call(
                digest: rootDescriptor.digest,
                reservationID: reservation?.reservationID
            )
        )
        if let reservation {
            await registry.release(reservation)
        }
    }
}

private struct BuilderHarnessContentProvider:
    RunnableImageContentProviding
{
    let rootDigest: String
    let indexValue: Index
    let manifestDigest: String
    let manifestValue: Manifest
    let configDigest: String
    let configValue: ContainerizationOCI.Image

    func index(for image: ClientImage) async throws -> Index {
        indexValue
    }

    func index(digest: String) async throws -> Index? {
        nil
    }

    func manifest(digest: String) async throws -> Manifest? {
        digest == manifestDigest ? manifestValue : nil
    }

    func config(digest: String) async throws
        -> ContainerizationOCI.Image?
    {
        digest == configDigest ? configValue : nil
    }
}

private actor BuilderHarnessSnapshotProvider:
    RunnableImageSnapshotProviding
{
    let filesystem: Filesystem
    private(set) var calls = 0

    init(filesystem: Filesystem) {
        self.filesystem = filesystem
    }

    func snapshot(
        for image: ClientImage,
        variant: RunnableImageVariant,
        descriptors: [ResolvedImageDescriptor],
        logger: Logger
    ) async throws -> RunnableImageSnapshot {
        calls += 1
        return RunnableImageSnapshot(filesystem: filesystem)
    }
}

private struct BuilderHarnessNetworkProvider: BuilderNetworkProviding {
    let network: NetworkResource

    func builtin() async throws -> NetworkResource? {
        network
    }
}

private struct BuilderHarnessKernelProvider: BuilderKernelProviding {
    let kernel = Kernel(
        path: URL(fileURLWithPath: "/tmp/socktainer-builder-test-kernel"),
        platform: .current
    )

    func defaultKernel() async throws -> Kernel {
        kernel
    }
}

private struct BuilderHarnessProcess: ClientProcess {
    let id: String
    let startOperation: @Sendable () async throws -> Void

    func start() async throws {
        try await startOperation()
    }

    func resize(_ size: ContainerizationOS.Terminal.Size) async throws {}
    func kill(_ signal: Int32) async throws {}
    func wait() async throws -> Int32 { 0 }
}

private actor BuilderHarnessRuntime: BuilderContainerRuntime {
    enum CreateBehavior: Sendable {
        case succeed
        case commitThenInterrupt
        case conflict
    }

    struct Metrics: Sendable {
        let createCalls: Int
        let bootstrapCalls: Int
        let stopCalls: Int
        let deleteCalls: Int
        let reservationObservedDuringCreate: Bool
        let rootFSOverride: Filesystem?
    }

    private var containers: [String: ContainerSnapshot] = [:]
    private let behavior: CreateBehavior
    private let reservationRegistry: ContainerImageLeaseReservationRegistry
    private let desiredRootDigest: String
    private let initialRunningDialUnavailable: Bool
    private var startFailuresRemaining: Int
    private var createCalls = 0
    private var bootstrapCalls = 0
    private var stopCalls = 0
    private var deleteCalls = 0
    private var reservationObservedDuringCreate = false
    private var rootFSOverride: Filesystem?

    init(
        behavior: CreateBehavior,
        reservationRegistry: ContainerImageLeaseReservationRegistry,
        desiredRootDigest: String,
        startFailures: Int,
        initialRunningDialUnavailable: Bool
    ) {
        self.behavior = behavior
        self.reservationRegistry = reservationRegistry
        self.desiredRootDigest = desiredRootDigest
        self.startFailuresRemaining = startFailures
        self.initialRunningDialUnavailable =
            initialRunningDialUnavailable
    }

    func install(_ snapshot: ContainerSnapshot) {
        containers[snapshot.id] = snapshot
    }

    func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        kernel: Kernel
    ) async throws {
        createCalls += 1
        rootFSOverride = options.rootFsOverride
        reservationObservedDuringCreate = await reservationRegistry.isReserved(
            rootDigest: desiredRootDigest
        )

        switch behavior {
        case .succeed:
            containers[configuration.id] = ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: []
            )
        case .commitThenInterrupt:
            containers[configuration.id] = ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: []
            )
            throw ContainerizationError(
                .interrupted,
                message: "simulated interrupted XPC reply"
            )
        case .conflict:
            var conflicting = configuration
            conflicting.image = ImageDescription(
                reference: "socktainer-runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest:
                        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    size: 2
                )
            )
            containers[configuration.id] = ContainerSnapshot(
                configuration: conflicting,
                status: .stopped,
                networks: []
            )
            throw ContainerizationError(
                .exists,
                message: "simulated conflicting container"
            )
        }
    }

    func get(id: String) async throws -> ContainerSnapshot {
        guard let snapshot = containers[id] else {
            throw ContainerizationError(
                .notFound,
                message: "container \(id) not found"
            )
        }
        return snapshot
    }

    func stop(id: String) async throws {
        stopCalls += 1
        guard var snapshot = containers[id] else {
            throw ContainerizationError(.notFound, message: id)
        }
        snapshot.status = .stopped
        containers[id] = snapshot
    }

    func delete(id: String, force: Bool) async throws {
        deleteCalls += 1
        guard containers.removeValue(forKey: id) != nil else {
            throw ContainerizationError(.notFound, message: id)
        }
    }

    func bootstrap(
        id: String,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        bootstrapCalls += 1
        guard containers[id] != nil else {
            throw ContainerizationError(.notFound, message: id)
        }
        return BuilderHarnessProcess(
            id: id,
            startOperation: { try await self.start(id: id) }
        )
    }

    func dial(id: String, port: UInt32) async throws -> FileHandle {
        if initialRunningDialUnavailable, createCalls == 0 {
            throw ContainerizationError(
                .invalidState,
                message: "simulated dead BuildKit shim"
            )
        }
        guard containers[id]?.status == .running else {
            throw ContainerizationError(.invalidState, message: id)
        }
        guard let handle = FileHandle(forReadingAtPath: "/dev/null") else {
            throw BuilderHarnessError.unsupportedOperation
        }
        return handle
    }

    func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        throw BuilderHarnessError.unsupportedOperation
    }

    func metrics() -> Metrics {
        Metrics(
            createCalls: createCalls,
            bootstrapCalls: bootstrapCalls,
            stopCalls: stopCalls,
            deleteCalls: deleteCalls,
            reservationObservedDuringCreate: reservationObservedDuringCreate,
            rootFSOverride: rootFSOverride
        )
    }

    private func markRunning(id: String) {
        guard var snapshot = containers[id] else { return }
        snapshot.status = .running
        containers[id] = snapshot
    }

    private func start(id: String) throws {
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw ContainerizationError(
                .invalidState,
                message: "simulated BuildKit restart failure"
            )
        }
        markRunning(id: id)
    }
}

private struct BuilderLifecycleHarness {
    enum ExistingBuilder {
        case none
        case compatibleRunning
        case compatibleStopped
        case staleRunning
    }

    let root: URL
    let sourceRootFS: URL
    let service: ClientBuilderService
    let runtime: BuilderHarnessRuntime
    let resolver: BuilderHarnessResolver
    let imageClient: BuilderHarnessImageClient
    let leaseManager: BuilderHarnessLeaseManager
    let leaseReconciler: BuilderHarnessLeaseReconciler
    let reservationRegistry: ContainerImageLeaseReservationRegistry
    let snapshotProvider: BuilderHarnessSnapshotProvider
    let desiredConfiguration: ContainerConfiguration
    let desiredRootDigest: String

    static func make(
        existing: ExistingBuilder = .none,
        createBehavior: BuilderHarnessRuntime.CreateBehavior = .succeed,
        imageAvailable: Bool = true,
        pullBehavior: BuilderHarnessImageClient.PullBehavior = .succeed,
        startFailures: Int = 0,
        initialRunningDialUnavailable: Bool = false
    ) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "socktainer-builder-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("containers", isDirectory: true),
            withIntermediateDirectories: true
        )
        do {
            let sourceRootFS = root.appendingPathComponent(
                "selected-rootfs.ext4",
                isDirectory: false
            )
            try Data(repeating: 0x5a, count: 8_192).write(to: sourceRootFS)
            let sourceFilesystem = Filesystem.block(
                format: "ext4",
                source: sourceRootFS.path,
                destination: "/",
                options: []
            )

            let rootDigest = digest("a")
            let manifestDigest = digest("b")
            let configDigest = digest("c")
            let platform = Platform(
                arch: "arm64",
                os: "linux",
                variant: "v8"
            )
            let rootDescriptor = Descriptor(
                mediaType: MediaTypes.index,
                digest: rootDigest,
                size: 100
            )
            let sourceImage = ClientImage(
                description: ImageDescription(
                    reference: "docker.io/library/builder-fixture:latest",
                    descriptor: rootDescriptor
                )
            )
            let identity = ResolvedImageIdentity(
                image: sourceImage,
                reference: sourceImage.reference,
                references: [sourceImage.reference],
                storeReferences: [sourceImage.reference],
                repositoryDigests: [],
                selectedStoreReference: sourceImage.reference,
                kind: .reference,
                variantConstraint: .unconstrained
            )
            let leaseImage = ClientImage(
                description: ImageDescription(
                    reference: ContainerImageLease.reference(
                        for: rootDigest
                    ),
                    descriptor: rootDescriptor
                )
            )
            let lease = ContainerImageLease(image: leaseImage)

            let configValue = ContainerizationOCI.Image(
                created: "2026-08-07T12:00:00Z",
                architecture: "arm64",
                os: "linux",
                variant: "v8",
                config: ImageConfig(env: ["PATH=/usr/local/bin:/usr/bin"]),
                rootfs: Rootfs(type: "layers", diffIDs: [])
            )
            let manifest = Manifest(
                config: Descriptor(
                    mediaType: MediaTypes.imageConfig,
                    digest: configDigest,
                    size: 20
                ),
                layers: []
            )
            let manifestDescriptor = Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: manifestDigest,
                size: 50,
                platform: platform
            )
            let contentProvider = BuilderHarnessContentProvider(
                rootDigest: rootDigest,
                indexValue: Index(manifests: [manifestDescriptor]),
                manifestDigest: manifestDigest,
                manifestValue: manifest,
                configDigest: configDigest,
                configValue: configValue
            )

            let network = try makeNetwork()
            let systemConfig = ContainerSystemConfig(
                build: BuildConfig(image: sourceImage.reference)
            )
            var desired =
                try ClientBuilderService
                .builderContainerConfiguration(
                    builderContainerId: "buildkit",
                    imageDescription: leaseImage.description,
                    imageEnv: configValue.config?.env,
                    useRosetta: systemConfig.build.rosetta,
                    builderCPUs: Int64(BuildConfig.defaultCPUs),
                    builderMemory: "2048MB",
                    exportsMountPath: root.appendingPathComponent("builder").path,
                    networkId: network.id,
                    nameserver: "192.168.64.1"
                )
            desired.labels[ClientBuilderService.specificationLabel] = try ClientBuilderService.builderSpecificationFingerprint(
                configuration: desired
            )

            let coordinator = ImageMutationCoordinator()
            let resolver = BuilderHarnessResolver(
                identity: identity,
                available: imageAvailable,
                mutationCoordinator: coordinator
            )
            let imageClient = BuilderHarnessImageClient(
                image: sourceImage,
                behavior: pullBehavior
            )
            let leaseManager = BuilderHarnessLeaseManager(lease: lease)
            let reservations = ContainerImageLeaseReservationRegistry()
            let reconciler = BuilderHarnessLeaseReconciler(
                registry: reservations
            )
            let runtime = BuilderHarnessRuntime(
                behavior: createBehavior,
                reservationRegistry: reservations,
                desiredRootDigest: rootDigest,
                startFailures: startFailures,
                initialRunningDialUnavailable:
                    initialRunningDialUnavailable
            )
            let snapshotProvider = BuilderHarnessSnapshotProvider(
                filesystem: sourceFilesystem
            )

            switch existing {
            case .none:
                break
            case .compatibleRunning:
                await runtime.install(
                    ContainerSnapshot(
                        configuration: desired,
                        status: .running,
                        networks: []
                    )
                )
            case .compatibleStopped:
                await runtime.install(
                    ContainerSnapshot(
                        configuration: desired,
                        status: .stopped,
                        networks: []
                    )
                )
            case .staleRunning:
                var stale = desired
                stale.labels.removeValue(
                    forKey: ClientBuilderService.specificationLabel
                )
                stale.image = ImageDescription(
                    reference: sourceImage.reference,
                    descriptor: Descriptor(
                        mediaType: MediaTypes.index,
                        digest: digest("d"),
                        size: 100
                    )
                )
                await runtime.install(
                    ContainerSnapshot(
                        configuration: stale,
                        status: .running,
                        networks: []
                    )
                )
            }

            let service = ClientBuilderService(
                appSupportURL: root,
                containerSystemConfig: systemConfig,
                imageResolver: resolver,
                imageClient: imageClient,
                imageMutationCoordinator: coordinator,
                imageLeaseManager: leaseManager,
                imageLeaseReservations: reservations,
                imageLeaseReconciler: reconciler,
                runnableImageSelector: RunnableImageSelector(
                    contentProvider: contentProvider
                ),
                snapshotProvider: snapshotProvider,
                rootFSMaterializer: ContainerRootFSMaterializer(
                    appSupportURL: root
                ),
                containerRuntime: runtime,
                networkProvider: BuilderHarnessNetworkProvider(
                    network: network
                ),
                kernelProvider: BuilderHarnessKernelProvider(),
                existingBuilderHealthTimeout: .milliseconds(20)
            )
            return Self(
                root: root,
                sourceRootFS: sourceRootFS,
                service: service,
                runtime: runtime,
                resolver: resolver,
                imageClient: imageClient,
                leaseManager: leaseManager,
                leaseReconciler: reconciler,
                reservationRegistry: reservations,
                snapshotProvider: snapshotProvider,
                desiredConfiguration: desired,
                desiredRootDigest: rootDigest
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private static func makeNetwork() throws -> NetworkResource {
        let subnet = try CIDRv4("192.168.64.0/24")
        let configuration = try NetworkConfiguration(
            name: "default",
            mode: .nat,
            ipv4Subnet: subnet,
            labels: ResourceLabels(),
            plugin: "container-network-vmnet"
        )
        return NetworkResource(
            configuration: configuration,
            status: NetworkStatus(
                ipv4Subnet: subnet,
                ipv4Gateway: try IPv4Address("192.168.64.1"),
                ipv6Subnet: nil
            )
        )
    }
}

@Suite("ClientBuilderService native lifecycle")
struct ClientBuilderServiceNativeLifecycleTests {
    private let logger = Logger(label: "socktainer.builder-tests")

    @Test("Exact selected snapshot is cloned and passed as rootfs override while reserved")
    func exactRootFSOverrideReachesNativeCreate() async throws {
        let harness = try await BuilderLifecycleHarness.make()
        defer { harness.cleanup() }

        let container = try await harness.service.runningBuilderContainer(
            logger: logger
        )
        let metrics = await harness.runtime.metrics()

        #expect(container.status == .running)
        #expect(metrics.createCalls == 1)
        #expect(metrics.bootstrapCalls == 1)
        #expect(metrics.reservationObservedDuringCreate)
        let rootFS = try #require(metrics.rootFSOverride)
        let expectedPath = harness.root.appendingPathComponent(
            "containers/buildkit/rootfs.ext4"
        ).path
        #expect(rootFS.source == expectedPath)
        #expect(rootFS.source != harness.sourceRootFS.path)
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: rootFS.source))
                == Data(contentsOf: harness.sourceRootFS)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.root.appendingPathComponent(
                    "containers/buildkit/\(PreparedContainerRootFS.ownershipMarkerFilename)"
                ).path
            )
        )
        #expect(
            !(await harness.reservationRegistry.isReserved(
                rootDigest: harness.desiredRootDigest
            ))
        )
        #expect(await harness.snapshotProvider.calls == 1)
        #expect(await harness.leaseManager.releaseCalls == 0)
    }

    @Test("Compatible running builder is reused without snapshot or native create")
    func compatibleRunningBuilderIsReused() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            existing: .compatibleRunning
        )
        defer { harness.cleanup() }

        let container = try await harness.service.runningBuilderContainer(
            logger: logger
        )
        let metrics = await harness.runtime.metrics()

        #expect(container.status == .running)
        #expect(metrics.createCalls == 0)
        #expect(metrics.bootstrapCalls == 0)
        #expect(metrics.stopCalls == 0)
        #expect(metrics.deleteCalls == 0)
        #expect(await harness.snapshotProvider.calls == 0)
        #expect(
            !(await harness.reservationRegistry.isReserved(
                rootDigest: harness.desiredRootDigest
            ))
        )
    }

    @Test("Compatible stopped builder is restarted without recreation")
    func compatibleStoppedBuilderIsRestarted() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            existing: .compatibleStopped
        )
        defer { harness.cleanup() }

        let container = try await harness.service.runningBuilderContainer(
            logger: logger
        )
        let metrics = await harness.runtime.metrics()

        #expect(container.status == .running)
        #expect(metrics.createCalls == 0)
        #expect(metrics.bootstrapCalls == 1)
        #expect(metrics.deleteCalls == 0)
        #expect(await harness.snapshotProvider.calls == 0)
        #expect(
            !(await harness.reservationRegistry.isReserved(
                rootDigest: harness.desiredRootDigest
            ))
        )
    }

    @Test("Compatible stopped builder with a failed restart is deleted and recreated")
    func failedStoppedBuilderRestartIsRecreated() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            existing: .compatibleStopped,
            startFailures: 1
        )
        defer { harness.cleanup() }

        let container = try await harness.service.runningBuilderContainer(
            logger: logger,
            readinessTimeout: .seconds(1),
            retryInterval: .milliseconds(5)
        )
        let metrics = await harness.runtime.metrics()

        #expect(container.status == .running)
        #expect(metrics.bootstrapCalls == 2)
        #expect(metrics.deleteCalls == 1)
        #expect(metrics.createCalls == 1)
        #expect(await harness.snapshotProvider.calls == 1)
    }

    @Test("Running native builder with a dead shim is deleted and recreated")
    func unreachableRunningBuilderIsRecreated() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            existing: .compatibleRunning,
            initialRunningDialUnavailable: true
        )
        defer { harness.cleanup() }

        let container = try await harness.service.runningBuilderContainer(
            logger: logger,
            readinessTimeout: .seconds(1),
            retryInterval: .milliseconds(5)
        )
        let metrics = await harness.runtime.metrics()

        #expect(container.status == .running)
        #expect(metrics.stopCalls == 1)
        #expect(metrics.deleteCalls == 1)
        #expect(metrics.createCalls == 1)
        #expect(metrics.bootstrapCalls == 1)
        #expect(await harness.snapshotProvider.calls == 1)
    }

    @Test("Stale builder is stopped, deleted, lease-reconciled, and recreated")
    func staleBuilderIsDeterministicallyRecreated() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            existing: .staleRunning
        )
        defer { harness.cleanup() }

        let container = try await harness.service.runningBuilderContainer(
            logger: logger
        )
        let metrics = await harness.runtime.metrics()
        let reconciliations = await harness.leaseReconciler.calls

        #expect(container.status == .running)
        #expect(container.configuration.image.reference.hasPrefix("socktainer-runtime@"))
        #expect(metrics.stopCalls == 1)
        #expect(metrics.deleteCalls == 1)
        #expect(metrics.createCalls == 1)
        #expect(metrics.bootstrapCalls == 1)
        #expect(
            reconciliations.contains {
                $0.digest
                    == "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
                    && $0.reservationID == nil
            }
        )
        #expect(
            reconciliations.contains {
                $0.digest == harness.desiredRootDigest
                    && $0.reservationID != nil
            }
        )
    }

    @Test("Committed native create survives an interrupted XPC reply")
    func commitThenInterruptedReplyConverges() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            createBehavior: .commitThenInterrupt
        )
        defer { harness.cleanup() }

        let container = try await harness.service.runningBuilderContainer(
            logger: logger
        )
        let metrics = await harness.runtime.metrics()

        #expect(container.status == .running)
        #expect(metrics.createCalls == 1)
        #expect(metrics.bootstrapCalls == 1)
        #expect(await harness.leaseManager.verifyCalls == 1)
        #expect(
            !(await harness.reservationRegistry.isReserved(
                rootDigest: harness.desiredRootDigest
            ))
        )
        #expect(await harness.leaseManager.releaseCalls == 0)
    }

    @Test("Conflicting native ID preserves its owner and releases only our reservation")
    func conflictingNativeIDDoesNotStealLease() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            createBehavior: .conflict
        )
        defer { harness.cleanup() }

        await #expect(throws: ContainerizationError.self) {
            _ = try await harness.service.runningBuilderContainer(
                logger: logger
            )
        }
        let metrics = await harness.runtime.metrics()
        let conflicting = try await harness.runtime.get(id: "buildkit")

        #expect(metrics.createCalls == 1)
        #expect(metrics.bootstrapCalls == 0)
        #expect(metrics.reservationObservedDuringCreate)
        #expect(
            conflicting.configuration.image.descriptor.digest
                == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
        #expect(
            !(await harness.reservationRegistry.isReserved(
                rootDigest: harness.desiredRootDigest
            ))
        )
        #expect(await harness.leaseManager.releaseCalls == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: harness.root.appendingPathComponent(
                    "containers/buildkit/rootfs.ext4"
                ).path
            )
        )
    }

    @Test("Pull failure clears the lifecycle gate for a later successful attempt")
    func pullFailureDoesNotPoisonLifecycle() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            imageAvailable: false,
            pullBehavior: .fail
        )
        defer { harness.cleanup() }

        await #expect(throws: BuilderHarnessError.pullFailed) {
            _ = try await harness.service.runningBuilderContainer(
                logger: logger
            )
        }
        #expect(await harness.imageClient.pullCalls == 1)
        #expect(
            !(await harness.reservationRegistry.isReserved(
                rootDigest: harness.desiredRootDigest
            ))
        )

        await harness.resolver.makeAvailable()
        let container = try await harness.service.runningBuilderContainer(
            logger: logger
        )
        #expect(container.status == .running)
        #expect((await harness.runtime.metrics()).createCalls == 1)
    }

    @Test("Cancelled pull clears the lifecycle gate for a later successful attempt")
    func pullCancellationDoesNotPoisonLifecycle() async throws {
        let harness = try await BuilderLifecycleHarness.make(
            imageAvailable: false,
            pullBehavior: .cancel
        )
        defer { harness.cleanup() }

        await #expect(throws: CancellationError.self) {
            _ = try await harness.service.runningBuilderContainer(
                logger: logger
            )
        }
        #expect(
            !(await harness.reservationRegistry.isReserved(
                rootDigest: harness.desiredRootDigest
            ))
        )

        await harness.resolver.makeAvailable()
        let container = try await harness.service.runningBuilderContainer(
            logger: logger
        )
        #expect(container.status == .running)
        #expect((await harness.runtime.metrics()).createCalls == 1)
    }
}
