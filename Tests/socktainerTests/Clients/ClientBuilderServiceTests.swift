import ContainerAPIClient
import ContainerBuild
import ContainerResource
import Containerization
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("ClientBuilderService.builderContainerConfiguration")
struct ClientBuilderServiceConfigurationTests {

    private func makeImageDescription() -> ImageDescription {
        ImageDescription(
            reference: "ghcr.io/apple/container-builder-shim/builder:0.12.0",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
    }

    @Test("Grants CAP_SYS_ADMIN so BuildKit's runc-native snapshotter can rbind-mount build contexts")
    func grantsCapSysAdmin() throws {
        let config = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: makeImageDescription(),
            imageEnv: nil,
            useRosetta: false,
            builderCPUs: 2,
            builderMemory: "2048MB",
            exportsMountPath: "/tmp/exports",
            networkId: "default",
            nameserver: "192.168.65.1"
        )
        #expect(config.capAdd == ["ALL"], "BuildKit's runc-native snapshotter needs CAP_SYS_ADMIN to rbind-mount build contexts — root alone is not sufficient (issue #260)")
    }

    @Test("Threads the builder id, network, and nameserver through to the resulting configuration")
    func threadsCoreIdentity() throws {
        let config = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: makeImageDescription(),
            imageEnv: ["PATH=/usr/bin"],
            useRosetta: true,
            builderCPUs: 4,
            builderMemory: "4096MB",
            exportsMountPath: "/tmp/exports",
            networkId: "mynet",
            nameserver: "192.168.65.1"
        )
        #expect(config.id == "buildkit")
        #expect(config.initProcess.environment == ["PATH=/usr/bin"])
        #expect(config.rosetta == true)
        #expect(config.networks.first?.network == "mynet")
        #expect(config.dns?.nameservers == ["192.168.65.1"])
    }

    @Test("Builder specification fingerprint is stable across creation timestamps")
    func stableSpecificationFingerprint() throws {
        var first = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: makeImageDescription(),
            imageEnv: ["PATH=/usr/bin"],
            useRosetta: true,
            builderCPUs: 4,
            builderMemory: "4096MB",
            exportsMountPath: "/tmp/exports",
            networkId: "default",
            nameserver: "192.168.65.1"
        )
        var second = first
        first.creationDate = Date(timeIntervalSince1970: 1)
        second.creationDate = Date(timeIntervalSince1970: 2)
        second.labels[ClientBuilderService.specificationLabel] = "stale"

        #expect(
            try ClientBuilderService.builderSpecificationFingerprint(
                configuration: first
            )
                == ClientBuilderService.builderSpecificationFingerprint(
                    configuration: second
                )
        )
    }

    @Test("Builder specification changes when its immutable image root changes")
    func specificationTracksImmutableRoot() throws {
        let first = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: makeImageDescription(),
            imageEnv: nil,
            useRosetta: false,
            builderCPUs: 2,
            builderMemory: "2048MB",
            exportsMountPath: "/tmp/exports",
            networkId: "default",
            nameserver: "192.168.65.1"
        )
        var second = first
        second.image = ImageDescription(
            reference: first.image.reference,
            descriptor: Descriptor(
                mediaType: first.image.descriptor.mediaType,
                digest: "sha256:def",
                size: first.image.descriptor.size
            )
        )

        #expect(
            try ClientBuilderService.builderSpecificationFingerprint(
                configuration: first
            )
                != ClientBuilderService.builderSpecificationFingerprint(
                    configuration: second
                )
        )
    }

    @Test("Compatibility requires both the fingerprint and exact hidden image identity")
    func compatibilityRequiresExactLeaseIdentity() throws {
        var desired = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: ImageDescription(
                reference:
                    "socktainer-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest:
                        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    size: 1
                )
            ),
            imageEnv: nil,
            useRosetta: false,
            builderCPUs: 2,
            builderMemory: "2048MB",
            exportsMountPath: "/tmp/exports",
            networkId: "default",
            nameserver: "192.168.65.1"
        )
        desired.labels[ClientBuilderService.specificationLabel] = try ClientBuilderService.builderSpecificationFingerprint(
            configuration: desired
        )
        let exact = ContainerSnapshot(
            configuration: desired,
            status: .running,
            networks: []
        )
        #expect(ClientBuilderService.isCompatibleBuilder(exact, desired: desired))

        var mutableTagConfiguration = desired
        mutableTagConfiguration.image = ImageDescription(
            reference: "ghcr.io/apple/container-builder-shim/builder:latest",
            descriptor: desired.image.descriptor
        )
        let mutableTag = ContainerSnapshot(
            configuration: mutableTagConfiguration,
            status: .running,
            networks: []
        )
        #expect(
            !ClientBuilderService.isCompatibleBuilder(
                mutableTag,
                desired: desired
            )
        )
    }
}

private actor BuilderPullDrainRecorder {
    private var resolveCalls = 0
    private var producedProgress = 0
    private(set) var pullCalls = 0
    private(set) var progressSeenBySecondResolve = 0

    func resolve(_ identity: ResolvedImageIdentity) throws
        -> ResolvedImageIdentity
    {
        resolveCalls += 1
        if resolveCalls == 1 {
            throw ImageIdentityResolutionError.notFound("builder")
        }
        progressSeenBySecondResolve = producedProgress
        return identity
    }

    func startedPull() {
        pullCalls += 1
    }

    func produced() {
        producedProgress += 1
    }
}

private actor BuilderLifecycleInvocationRecorder {
    private(set) var count = 0

    func begin() {
        count += 1
    }
}

private actor RecordingBuilderBuildSession: BuilderBuildSession {
    private(set) var closeCount = 0

    func build(_ configuration: Builder.BuildConfig) async throws {
        fatalError("not exercised by session lifetime tests")
    }

    func close() {
        closeCount += 1
    }
}

@Suite("ClientBuilderService lifecycle architecture")
struct ClientBuilderServiceLifecycleTests {
    private static func identity() -> ResolvedImageIdentity {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest:
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            size: 1
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/builder:latest",
                descriptor: descriptor
            )
        )
        return ResolvedImageIdentity(
            image: image,
            reference: image.reference,
            references: [image.reference],
            storeReferences: [image.reference],
            repositoryDigests: [],
            selectedStoreReference: image.reference,
            kind: .reference,
            variantConstraint: .unconstrained
        )
    }

    private static func snapshot() -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let config = ContainerConfiguration(
            id: "buildkit",
            image: identity().image.description,
            process: process
        )
        return ContainerSnapshot(
            configuration: config,
            status: .running,
            networks: []
        )
    }

    @Test("Missing builder pull is fully drained before canonical re-resolution")
    func pullIsFullyDrained() async throws {
        let recorder = BuilderPullDrainRecorder()
        let expected = Self.identity()

        let resolved = try await ClientBuilderService.resolveOrPull(
            reference: expected.reference,
            platform: Platform(arch: "arm64", os: "linux", variant: "v8"),
            resolve: { try await recorder.resolve(expected) },
            pull: { _ in
                await recorder.startedPull()
                return AsyncThrowingStream { continuation in
                    Task {
                        await recorder.produced()
                        continuation.yield(.message("downloaded"))
                        await recorder.produced()
                        continuation.yield(.message("imported"))
                        continuation.finish()
                    }
                }
            }
        )

        #expect(resolved.image.digest == expected.image.digest)
        #expect(await recorder.pullCalls == 1)
        #expect(await recorder.progressSeenBySecondResolve == 2)
    }

    @Test("Concurrent callers share one native builder lifecycle operation")
    func concurrentLifecycleIsCoalesced() async throws {
        let coordinator = BuilderLifecycleCoordinator()
        let recorder = BuilderLifecycleInvocationRecorder()
        let expected = Self.snapshot()

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await coordinator.run {
                        await recorder.begin()
                        try await Task.sleep(for: .milliseconds(50))
                        return expected
                    }.id
                }
            }
            for try await id in group {
                #expect(id == "buildkit")
            }
        }

        #expect(await recorder.count == 1)
    }

    @Test("A failed lifecycle operation does not poison future creation")
    func lifecycleRetriesAfterFailure() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let coordinator = BuilderLifecycleCoordinator()
        let recorder = BuilderLifecycleInvocationRecorder()
        await #expect(throws: ExpectedFailure.firstAttempt) {
            _ = try await coordinator.run {
                await recorder.begin()
                throw ExpectedFailure.firstAttempt
            }
        }
        let result = try await coordinator.run {
            await recorder.begin()
            return Self.snapshot()
        }

        #expect(result.id == "buildkit")
        #expect(await recorder.count == 2)
    }

    @Test("Builder sessions close exactly once after successful use")
    func builderSessionClosesAfterSuccess() async throws {
        let session = RecordingBuilderBuildSession()

        let result = try await BuilderSessionLifecycle.withSession(session) {
            _ in 42
        }

        #expect(result == 42)
        #expect(await session.closeCount == 1)
    }

    @Test("Builder sessions close exactly once after failed use")
    func builderSessionClosesAfterFailure() async throws {
        enum ExpectedFailure: Error { case build }
        let session = RecordingBuilderBuildSession()

        await #expect(throws: ExpectedFailure.build) {
            _ = try await BuilderSessionLifecycle.withSession(session) { _ in
                throw ExpectedFailure.build
            }
        }

        #expect(await session.closeCount == 1)
    }
}
