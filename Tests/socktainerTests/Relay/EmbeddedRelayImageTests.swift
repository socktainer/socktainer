import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import CryptoKit
import Foundation
import NIOPosix
import SystemPackage
import Testing

@testable import socktainer

private actor RelayRaceGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor RelayRaceSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Embedded network relay")
struct EmbeddedRelayImageTests {
    @Test("cleanup invalidates delayed ensure waiters without disturbing re-ensure")
    func cleanupEnsureGenerationRace() async throws {
        let root = try RequestBodyFileWriter.createSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let metadataRoot = root.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(
            at: metadataRoot,
            withIntermediateDirectories: false
        )
        let manager = try NetworkRelayManager(
            appSupportURL: root,
            runtimeRoot: metadataRoot,
            containerSystemConfig: ContainerSystemConfig(),
            imageClient: ClientImageService(containerSystemConfig: ContainerSystemConfig()),
            eventLoopGroup: group
        )
        let runtimeRoot = NetworkRelayManager.shortRuntimeRoot(seed: metadataRoot)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let network = "relay-race-\(UUID().uuidString.lowercased())"
        let oldWork = RelayRaceGate()
        let followerJoined = RelayRaceSignal()
        let staleCompletion = RelayRaceGate()

        let creator = Task {
            try await manager.ensureRelayForTesting(networkID: network) {
                await oldWork.arriveAndWait()
                return "/tmp/old-relay.sock"
            }
        }
        await oldWork.waitUntilArrived()

        let staleWaiter = Task {
            try await manager.ensureRelayForTesting(
                networkID: network,
                work: {
                    Issue.record("a follower must join the existing relay operation")
                    return "/tmp/unexpected.sock"
                },
                onJoined: { await followerJoined.signal() },
                afterWork: { await staleCompletion.arriveAndWait() }
            )
        }
        await followerJoined.wait()

        let cleanup = Task {
            await manager.cleanupRelayForTesting(networkID: network)
        }
        while !(await manager.cleanupInProgressForTesting(networkID: network)) {
            await Task.yield()
        }
        await oldWork.release()
        await staleCompletion.waitUntilArrived()
        await cleanup.value

        let newWork = RelayRaceGate()
        let replacement = Task {
            try await manager.ensureRelayForTesting(networkID: network) {
                await newWork.arriveAndWait()
                return "/tmp/new-relay.sock"
            }
        }
        await newWork.waitUntilArrived()

        await staleCompletion.release()
        await #expect(throws: CancellationError.self) { try await staleWaiter.value }
        await #expect(throws: CancellationError.self) { try await creator.value }

        // If either stale waiter removed the replacement's pending entry, this
        // concurrent follower would execute its own work instead of joining it.
        let replacementFollower = Task {
            try await manager.ensureRelayForTesting(networkID: network) {
                Issue.record("stale completion removed the replacement operation")
                return "/tmp/unexpected-replacement.sock"
            }
        }
        await newWork.release()
        #expect(try await replacement.value == "/tmp/new-relay.sock")
        #expect(try await replacementFollower.value == "/tmp/new-relay.sock")
        try await group.shutdownGracefully()
    }

    @Test("embedded OCI bytes match the reviewed arm64 artifact")
    func artifactDigest() {
        let digest = SHA256.hash(data: SocktainerRelayImage.archiveData).hexString
        #expect(digest == "706ea8e3b48885c643d359080f97df33b4f399b43bc68b4981c424fc481a7958")
    }

    @Test("loadable archive owns the canonical tag and advertises arm64")
    func preparedArchive() throws {
        let canonical = "docker.io/library/socktainer-port-relay:embedded"
        let prepared = try EmbeddedRelayImage.prepareLoadableArchive(canonicalTag: canonical)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let layout = prepared.directory.appendingPathComponent("verify")
        try ArchiveUtility.extract(
            tarPath: prepared.archive,
            to: layout,
            limits: .imageLoad,
            transactional: true
        )
        let index = try JSONDecoder().decode(
            Index.self,
            from: Data(contentsOf: layout.appendingPathComponent("index.json"))
        )
        #expect(index.manifests.count == 1)
        let descriptor = index.manifests[0]
        #expect(descriptor.digest == SocktainerRelayImage.rootDigest)
        #expect(descriptor.platform == .current)
        #expect(descriptor.annotations?[AnnotationKeys.containerizationImageName] == canonical)
        #expect(descriptor.annotations?[AnnotationKeys.containerdImageName] == canonical)
        #expect(descriptor.annotations?[AnnotationKeys.openContainersImageName] == canonical)
    }

    @Test("relay socket path is deterministic, bounded, and private")
    func privateSocketDirectory() throws {
        let root = try RequestBodyFileWriter.createSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let longNetwork = String(repeating: "network-", count: 20)
        let shortRoot = NetworkRelayManager.shortRuntimeRoot(seed: root)
        defer { try? FileManager.default.removeItem(at: shortRoot) }
        try NetworkRelayManager.ensurePrivateDirectory(shortRoot)
        let first = NetworkRelayManager.socketPath(for: longNetwork, under: shortRoot)
        let second = NetworkRelayManager.socketPath(for: longNetwork, under: shortRoot)
        #expect(first == second)
        #expect(first.utf8.count < 104)
        #expect(first.hasSuffix("/relay.sock"))
        let attributes = try FileManager.default.attributesOfItem(atPath: shortRoot.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: POSIXError(.EACCES)) {
            try NetworkRelayManager.ensurePrivateDirectory(link)
        }
    }

    @Test("published relay sockets are narrowed to owner-only access")
    func socketPermissionNormalization() async throws {
        let root = try RequestBodyFileWriter.createSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("relay.sock").path
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .bind(unixDomainSocketPath: socketPath)
            .get()
        #expect(chmod(socketPath, 0o755) == 0)
        #expect(NetworkRelayManager.securePublishedSocket(at: socketPath))
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await channel.close()
        try await group.shutdownGracefully()
    }

    @Test("relay reuse requires the expected OCI root digest")
    func reuseRequiresImageIdentity() async throws {
        let root = try RequestBodyFileWriter.createSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("relay.sock").path
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .bind(unixDomainSocketPath: socketPath)
            .get()
        #expect(chmod(socketPath, 0o600) == 0)
        let owner = "0123456789abcdef"
        let digest = "sha256:expected-relay-root"
        let snapshot = try makeContainerSnapshot(
            nativeId: "socktainer-relay-identity-test",
            networks: [(network: "test_default", ip: "192.168.65.3")],
            labels: [
                NetworkDNSManager.roleLabel: NetworkRelayManager.relayRole,
                NetworkRelayManager.artifactLabel: SocktainerRelayImage.artifactSHA256,
                NetworkRelayManager.ownerLabel: owner,
            ],
            imageDigest: digest,
            publishedSockets: [
                try PublishSocket(
                    containerPath: FilePath(NetworkRelayManager.guestSocketPath),
                    hostPath: FilePath(socketPath),
                    permissions: FilePermissions(rawValue: 0o600)
                )
            ]
        )
        #expect(
            NetworkRelayManager.isUsable(
                snapshot,
                hostSocket: socketPath,
                ownerID: owner,
                expectedImageDigest: digest
            )
        )
        #expect(
            !NetworkRelayManager.isUsable(
                snapshot,
                hostSocket: socketPath,
                ownerID: owner,
                expectedImageDigest: "sha256:different-root"
            )
        )
        try await channel.close()
        try await group.shutdownGracefully()
    }

    @Test("relay sidecars are hidden as Socktainer infrastructure")
    func infrastructureVisibility() throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "socktainer-relay-test",
            networks: [(network: "test_default", ip: "192.168.65.3")],
            labels: [
                NetworkDNSManager.roleLabel: NetworkRelayManager.relayRole,
                NetworkDNSManager.networkLabel: "test_default",
            ]
        )
        #expect(NetworkRelayManager.isRelay(snapshot))
        #expect(ClientContainerService.isInfrastructureSidecar(snapshot))
        #expect(!ClientContainerService.isDNSSidecar(snapshot))
    }

    @Test("relay ownership isolates concurrent Socktainer instances")
    func instanceOwnership() throws {
        let firstRoot = URL(fileURLWithPath: "/tmp/socktainer-instance-a/metadata")
        let secondRoot = URL(fileURLWithPath: "/tmp/socktainer-instance-b/metadata")
        let firstOwner = NetworkRelayManager.ownerID(seed: firstRoot)
        let secondOwner = NetworkRelayManager.ownerID(seed: secondRoot)
        #expect(firstOwner == NetworkRelayManager.ownerID(seed: firstRoot))
        #expect(firstOwner != secondOwner)
        #expect(
            NetworkRelayManager.containerID(for: "shared-network", ownerID: firstOwner)
                != NetworkRelayManager.containerID(for: "shared-network", ownerID: secondOwner)
        )

        let snapshot = try makeContainerSnapshot(
            nativeId: NetworkRelayManager.containerID(
                for: "shared-network",
                ownerID: firstOwner
            ),
            networks: [(network: "shared-network", ip: "192.168.65.3")],
            labels: [
                NetworkDNSManager.roleLabel: NetworkRelayManager.relayRole,
                NetworkDNSManager.networkLabel: "shared-network",
                NetworkRelayManager.ownerLabel: firstOwner,
            ]
        )
        #expect(NetworkRelayManager.isOwnedRelay(snapshot, ownerID: firstOwner))
        #expect(!NetworkRelayManager.isOwnedRelay(snapshot, ownerID: secondOwner))
    }
}
