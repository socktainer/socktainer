import ContainerResource
import ContainerizationExtras
import Darwin
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private actor DelayedRecoveryState {
    enum ExpectedFailure: Error { case unavailable }

    private var snapshot: ContainerSnapshot
    private var listAttempts = 0

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

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

private actor ScopedRecoveryRelayProvider: NetworkPortRelayProviding {
    private var networks: [String] = []

    func ensureRelay(
        networkID: String,
        checking destination: PortRelayProtocol.Destination
    ) async throws -> String {
        networks.append(networkID)
        return "/tmp/socktainer-scoped-recovery-relay-missing.sock"
    }

    func cleanupRelay(networkID: String) async {}
    func count() -> Int { networks.count }
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

        do {
            try await withApp { app in
                let state = DelayedRecoveryState(snapshot: owned)
                let dnsServer = SocktainerDNSServer()
                let relayProvider = ScopedRecoveryRelayProvider()
                let portManager = PublishedPortManager(
                    eventLoopGroup: app.eventLoopGroup,
                    logger: Logger(label: "socktainer.tests.scoped-replacement"),
                    relayProvider: relayProvider
                )
                let requestedPort = try PublishPort(
                    hostAddress: IPAddress("127.0.0.1"),
                    hostPort: 0,
                    containerPort: 5432,
                    proto: .tcp,
                    count: 1
                )
                let reservation = try await portManager.reserveDynamicPorts([requestedPort])
                let hostPort = try #require(reservation.ports.first?.hostPort)
                await portManager.commit(reservation, nativeID: nativeID)
                try await DockerContainerMetadataStore.shared.set(
                    nativeID: nativeID,
                    name: "owned-scoped-container",
                    publishedPorts: reservation.ports
                )
                let monitor = RecoveredContainerLifecycleMonitor(
                    client: DelayedRecoveryClient(state: state),
                    portManager: portManager,
                    dnsServer: dnsServer,
                    healthManager: HealthCheckManager(),
                    logger: app.logger,
                    requiredOwnerID: ownerID
                )

                await monitor.start(containers: [owned])
                #expect(dnsServer.listEntries()["owned-scoped-container"] == "192.168.65.44")
                #expect(await relayProvider.count() == 1)
                #expect(!Self.canBindTCP(port: hostPort))

                await state.replace(with: foreign)
                // The first synthetic list call models a transient Apple outage;
                // the next poll must reject the replacement generation.
                await monitor.pollOnce()
                await monitor.pollOnce()

                #expect(dnsServer.listEntries()["owned-scoped-container"] == nil)
                #expect(dnsServer.listEntries()["foreign-database"] == nil)
                #expect(await relayProvider.count() == 1)
                #expect(Self.canBindTCP(port: hostPort))
                #expect(
                    await DockerContainerMetadataStore.shared.entry(nativeID: nativeID)?.name
                        == "owned-scoped-container"
                )

                await monitor.shutdown()
                await portManager.shutdown()
            }
        } catch {
            await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: owned))
            try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            throw error
        }
        await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: owned))
        try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
    }

    private static func canBindTCP(port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return false
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
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

        do {
            try await withApp { app in
                let dnsServer = SocktainerDNSServer()
                let healthManager = HealthCheckManager()
                let relayProvider = ScopedRecoveryRelayProvider()
                let portManager = PublishedPortManager(
                    eventLoopGroup: app.eventLoopGroup,
                    logger: Logger(label: "socktainer.tests.scoped-recovery"),
                    relayProvider: relayProvider
                )
                let monitor = RecoveredContainerLifecycleMonitor(
                    client: DelayedRecoveryClient(
                        state: DelayedRecoveryState(snapshot: snapshot)
                    ),
                    portManager: portManager,
                    dnsServer: dnsServer,
                    healthManager: healthManager,
                    logger: app.logger,
                    requiredOwnerID: ownerID
                )

                await monitor.start(containers: [snapshot])
                #expect(await DockerContainerMetadataStore.shared.entry(nativeID: nativeID) == nil)
                #expect(dnsServer.listEntries()[nativeID] == nil)
                #expect(await relayProvider.count() == 0)
                await monitor.shutdown()

                try await DockerContainerMetadataStore.shared.set(
                    nativeID: nativeID,
                    name: "owned-scoped-container",
                    publishedPorts: [
                        try PublishPort(
                            hostAddress: IPAddress("127.0.0.1"),
                            hostPort: 55_491,
                            containerPort: 5432,
                            proto: .tcp,
                            count: 1
                        )
                    ]
                )
                let wrongOwnerMonitor = RecoveredContainerLifecycleMonitor(
                    client: DelayedRecoveryClient(
                        state: DelayedRecoveryState(snapshot: wrongOwner)
                    ),
                    portManager: portManager,
                    dnsServer: dnsServer,
                    healthManager: healthManager,
                    logger: app.logger,
                    requiredOwnerID: ownerID
                )
                await wrongOwnerMonitor.start(containers: [wrongOwner])
                #expect(dnsServer.listEntries()["owned-scoped-container"] == nil)
                #expect(await relayProvider.count() == 0)
                await wrongOwnerMonitor.shutdown()

                let ownedMonitor = RecoveredContainerLifecycleMonitor(
                    client: DelayedRecoveryClient(
                        state: DelayedRecoveryState(snapshot: snapshot)
                    ),
                    portManager: portManager,
                    dnsServer: dnsServer,
                    healthManager: healthManager,
                    logger: app.logger,
                    requiredOwnerID: ownerID
                )
                await ownedMonitor.start(containers: [snapshot])
                #expect(
                    await DockerContainerMetadataStore.shared.name(nativeID: nativeID)
                        == "owned-scoped-container"
                )
                #expect(
                    dnsServer.listEntries()["owned-scoped-container"]
                        == "192.168.65.43"
                )
                #expect(await relayProvider.count() == 1)

                await ownedMonitor.shutdown()
                await portManager.shutdown()
            }
        } catch {
            await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: snapshot))
            try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            throw error
        }
        await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: snapshot))
        try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
    }

    @Test("a container discovered after an initial Apple outage restores all daemon state")
    func delayedDiscoveryRecovery() async throws {
        let nativeID = "legacy-recovery-\(UUID().uuidString.lowercased())"
        let healthcheck = HealthcheckConfig(
            Test: ["CMD", "true"],
            Interval: 10_000_000_000,
            Timeout: 1_000_000_000,
            Retries: 3,
            StartPeriod: nil
        )
        let healthJSON = String(
            decoding: try JSONEncoder().encode(healthcheck),
            as: UTF8.self
        )
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

        do {
            try await withApp { app in
                let dnsServer = SocktainerDNSServer()
                let healthManager = HealthCheckManager(
                    probe: { _, _, _ in
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        return 0
                    },
                    intervalFloorNs: 1_000_000
                )
                let portManager = PublishedPortManager(
                    eventLoopGroup: app.eventLoopGroup,
                    logger: Logger(label: "socktainer.tests.recovery")
                )
                let monitor = RecoveredContainerLifecycleMonitor(
                    client: DelayedRecoveryClient(
                        state: DelayedRecoveryState(snapshot: snapshot)
                    ),
                    portManager: portManager,
                    dnsServer: dnsServer,
                    healthManager: healthManager,
                    logger: app.logger
                )

                await monitor.pollOnce()
                #expect(await DockerContainerMetadataStore.shared.entry(nativeID: nativeID) == nil)

                await monitor.pollOnce()
                #expect(await DockerContainerMetadataStore.shared.name(nativeID: nativeID) == nativeID)
                #expect(dnsServer.listEntries()[nativeID] == "192.168.65.42")
                #expect(dnsServer.listEntries()["database"] == "192.168.65.42")
                #expect(dnsServer.listEntries()["database.recovery"] == "192.168.65.42")
                #expect(
                    await ContainerInfoCache.shared.get(
                        id: DockerContainerID.hexId(for: snapshot)
                    )?.nativeId == nativeID
                )
                #expect(await healthManager.currentHealth(for: nativeID) != nil)

                await monitor.shutdown()
                await healthManager.stop(containerId: nativeID)
                await portManager.shutdown()
            }
        } catch {
            await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: snapshot))
            try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            throw error
        }
        await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: snapshot))
        try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
    }
}
