import ContainerResource
import ContainerizationExtras
import Foundation
import Logging
import Testing

@testable import socktainer

private actor DelayedRecoveryState {
    enum ExpectedFailure: Error { case unavailable }

    private var snapshot: ContainerSnapshot
    private var listAttempts = 0

    init(snapshot: ContainerSnapshot) { self.snapshot = snapshot }

    func list() throws -> [ContainerSnapshot] {
        listAttempts += 1
        if listAttempts == 1 { throw ExpectedFailure.unavailable }
        return [snapshot]
    }

    func current() -> ContainerSnapshot { snapshot }
    func replace(with snapshot: ContainerSnapshot) { self.snapshot = snapshot }
}

private struct DelayedRecoveryClient: ClientContainerProtocol {
    let state: DelayedRecoveryState

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        try await state.list()
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let snapshot = await state.current()
        return snapshot.id == id ? snapshot : nil
    }

    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (
        deletedContainers: [String], spaceReclaimed: Int64
    ) {
        ([], 0)
    }
}

@Suite("Recovered container lifecycle monitor", .serialized)
struct RecoveredContainerLifecycleMonitorTests {
    @Test("metadata-scoped recovery retires an owned ID replaced by a foreign generation")
    func metadataScopedReplacement() async throws {
        let nativeID = "scoped-replacement-\(UUID().uuidString.lowercased())"
        let ownerID = "0123456789abcdef"
        let owned = try makeContainerSnapshot(
            nativeId: nativeID,
            ip: "192.168.65.44",
            network: "scoped_default",
            labels: [
                "com.docker.compose.service": "database",
                ContainerImageIdentity.instanceOwnerLabel: ownerID,
            ],
            status: .running
        )
        let foreign = try makeContainerSnapshot(
            nativeId: nativeID,
            ip: "192.168.65.99",
            network: "foreign_default",
            labels: [
                "com.docker.compose.service": "foreign-database",
                ContainerImageIdentity.instanceOwnerLabel: "fedcba9876543210",
            ],
            status: .running
        )
        try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
        defer {
            Task {
                await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: owned))
                try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            }
        }

        let state = DelayedRecoveryState(snapshot: owned)
        let dnsServer = SocktainerDNSServer()
        try await DockerContainerMetadataStore.shared.set(
            nativeID: nativeID,
            name: "owned-scoped-container",
            publishedPorts: []
        )
        let monitor = RecoveredContainerLifecycleMonitor(
            client: DelayedRecoveryClient(state: state),
            dnsServer: dnsServer,
            healthManager: HealthCheckManager(),
            logger: Logger(label: "socktainer.tests.scoped-replacement"),
            requiredOwnerID: ownerID
        )

        await monitor.start(containers: [owned])
        #expect(dnsServer.listEntries()["owned-scoped-container"] == "192.168.65.44")
        await state.replace(with: foreign)
        await monitor.pollOnce()
        await monitor.pollOnce()

        #expect(dnsServer.listEntries()["owned-scoped-container"] == nil)
        #expect(dnsServer.listEntries()["foreign-database"] == nil)
        #expect(
            await DockerContainerMetadataStore.shared.entry(nativeID: nativeID)?.name
                == "owned-scoped-container"
        )
        await monitor.shutdown()
    }

    @Test("metadata-scoped recovery ignores foreign containers and recovers owned containers")
    func metadataScopedRecovery() async throws {
        let nativeID = "scoped-recovery-\(UUID().uuidString.lowercased())"
        let ownerID = "0123456789abcdef"
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeID,
            ip: "192.168.65.43",
            network: "scoped_default",
            labels: [
                "com.docker.compose.service": "database",
                ContainerImageIdentity.instanceOwnerLabel: ownerID,
            ],
            status: .running
        )
        let wrongOwner = try makeContainerSnapshot(
            nativeId: nativeID,
            ip: "192.168.65.98",
            network: "foreign_default",
            labels: [ContainerImageIdentity.instanceOwnerLabel: "fedcba9876543210"],
            status: .running
        )
        try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
        defer {
            Task {
                await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: snapshot))
                try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            }
        }

        let dnsServer = SocktainerDNSServer()
        let healthManager = HealthCheckManager()
        let monitor = RecoveredContainerLifecycleMonitor(
            client: DelayedRecoveryClient(state: DelayedRecoveryState(snapshot: snapshot)),
            dnsServer: dnsServer,
            healthManager: healthManager,
            logger: Logger(label: "socktainer.tests.scoped-recovery"),
            requiredOwnerID: ownerID
        )
        await monitor.start(containers: [wrongOwner])
        #expect(await DockerContainerMetadataStore.shared.entry(nativeID: nativeID) == nil)
        #expect(dnsServer.listEntries()[nativeID] == nil)
        await monitor.shutdown()

        try await DockerContainerMetadataStore.shared.set(
            nativeID: nativeID,
            name: "owned-scoped-container",
            publishedPorts: []
        )
        let ownedMonitor = RecoveredContainerLifecycleMonitor(
            client: DelayedRecoveryClient(state: DelayedRecoveryState(snapshot: snapshot)),
            dnsServer: dnsServer,
            healthManager: healthManager,
            logger: Logger(label: "socktainer.tests.scoped-recovery"),
            requiredOwnerID: ownerID
        )
        await ownedMonitor.start(containers: [snapshot])
        #expect(
            await DockerContainerMetadataStore.shared.name(nativeID: nativeID)
                == "owned-scoped-container"
        )
        #expect(dnsServer.listEntries()["owned-scoped-container"] == "192.168.65.43")
        await ownedMonitor.shutdown()
    }

    @Test("a container discovered after an initial Apple outage restores daemon state")
    func delayedDiscoveryRecovery() async throws {
        let nativeID = "recovery-\(UUID().uuidString.lowercased())"
        let healthcheck = HealthcheckConfig(
            Test: ["CMD", "true"],
            Interval: 10_000_000_000,
            Timeout: 1_000_000_000,
            Retries: 3,
            StartPeriod: nil
        )
        let healthJSON = String(decoding: try JSONEncoder().encode(healthcheck), as: UTF8.self)
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeID,
            ip: "192.168.65.42",
            network: "recovery_default",
            labels: [
                HealthCheckManager.healthcheckLabel: healthJSON,
                "com.docker.compose.service": "database",
                "com.docker.compose.project": "recovery",
            ],
            status: .running
        )
        try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
        defer {
            Task {
                await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: snapshot))
                try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            }
        }

        let dnsServer = SocktainerDNSServer()
        let healthManager = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let monitor = RecoveredContainerLifecycleMonitor(
            client: DelayedRecoveryClient(state: DelayedRecoveryState(snapshot: snapshot)),
            dnsServer: dnsServer,
            healthManager: healthManager,
            logger: Logger(label: "socktainer.tests.recovery")
        )

        await monitor.pollOnce()
        #expect(await DockerContainerMetadataStore.shared.entry(nativeID: nativeID) == nil)
        await monitor.pollOnce()
        #expect(await DockerContainerMetadataStore.shared.name(nativeID: nativeID) == nativeID)
        #expect(dnsServer.listEntries()[nativeID] == "192.168.65.42")
        #expect(dnsServer.listEntries()["database"] == "192.168.65.42")
        #expect(dnsServer.listEntries()["database.recovery"] == "192.168.65.42")
        #expect(await healthManager.currentHealth(for: nativeID) != nil)

        await monitor.shutdown()
        await healthManager.stop(containerId: nativeID)
    }
}
