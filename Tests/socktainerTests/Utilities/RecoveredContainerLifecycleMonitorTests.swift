import ContainerResource
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private actor DelayedRecoveryState {
    enum ExpectedFailure: Error { case unavailable }

    let snapshot: ContainerSnapshot
    private var listAttempts = 0

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func list() throws -> [ContainerSnapshot] {
        listAttempts += 1
        if listAttempts == 1 { throw ExpectedFailure.unavailable }
        return [snapshot]
    }
}

private struct DelayedRecoveryClient: ClientContainerProtocol {
    let state: DelayedRecoveryState

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        try await state.list()
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let snapshot = state.snapshot
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
