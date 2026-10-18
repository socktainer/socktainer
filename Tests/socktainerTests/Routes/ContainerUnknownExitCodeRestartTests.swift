import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests: when the authoritative exit wait fails, `ContainerExitCodeStore`
/// records `waitFailureSentinel` (-1) so callers can tell a failed wait from a real
/// exit 0. The restart observer read that sentinel as an ordinary exit code, and a
/// non-zero code means "the process failed" to `on-failure` — so a container whose
/// exit status was never observed got restarted on a crash that may not have
/// happened. An unknown exit status must not authorize a restart.
@Suite("ContainerStartRoute — unknown exit status does not restart on-failure")
struct ContainerUnknownExitCodeRestartTests {

    @Test("An on-failure container is not restarted when its exit code is unknown")
    func unknownExitCodeDoesNotRestart() async throws {
        let nativeId = "restart-unknown-exit-ctr"
        let ip = "192.168.65.90"
        let network = "myapp_default"

        let mock = UnknownExitMock(
            snapshot: try unknownExitSnapshot(nativeId: nativeId, ip: ip, network: network, restartPolicyName: "on-failure"))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // Resolve the armed observer's wait with the sentinel, exactly as a failed
        // authoritative wait does.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: ContainerExitCodeStore.waitFailureSentinel)

        // Give the observer the same window the restart tests use to observe a restart.
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(
            await mock.startCallCount() == 1,
            "on-failure must not restart a container whose exit status was never observed")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("An on-failure container still restarts on a real non-zero exit")
    func knownNonZeroExitCodeStillRestarts() async throws {
        // An unknown exit bails out of the observer; a real code must not.
        let nativeId = "restart-known-exit-ctr"
        let ip = "192.168.65.91"
        let network = "myapp_default"

        let mock = UnknownExitMock(
            snapshot: try unknownExitSnapshot(nativeId: nativeId, ip: ip, network: network, restartPolicyName: "on-failure"))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 17)
        let restarted = try await pollUntil(timeoutSeconds: 5) { await mock.startCallCount() >= 2 }
        #expect(restarted, "a real non-zero exit must still trigger the on-failure restart")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("A stopped container still runs DNS and --rm cleanup when its exit code is unknown")
    func unknownExitCodeCleansUpConfirmedStoppedContainer() async throws {
        let nativeId = "restart-unknown-exit-stopped-cleanup-ctr"
        let ip = "192.168.65.92"
        let network = "myapp_default"

        let snapshot = try unknownExitSnapshot(
            nativeId: nativeId, ip: ip, network: network, restartPolicyName: "on-failure", status: .stopped)
        let hexId = DockerContainerID.hexId(for: snapshot)
        let mock = UnknownExitMock(snapshot: snapshot)
        let dnsServer = SocktainerDNSServer()

        await ContainerInfoCache.shared.markAutoRemove(hexId: hexId, nativeId: nativeId)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(dnsServer.listEntries()[nativeId] == ip)

        await ContainerExitCodeStore.shared.set(id: nativeId, code: ContainerExitCodeStore.waitFailureSentinel)

        let cleaned = try await pollUntil(timeoutSeconds: 2) {
            dnsServer.listEntries()[nativeId] == nil
        }
        #expect(cleaned, "a confirmed-stopped container must still unregister its DNS alias when wait fails")
        #expect(await ContainerInfoCache.shared.get(id: hexId) == nil, "--rm cache entry must be cleaned up when confirmed stopped")
        #expect(await mock.startCallCount() == 1, "cleanup must not trigger a restart")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("A still-running container keeps its DNS alias when the exit wait fails")
    func unknownExitCodePreservesRunningContainerAliases() async throws {
        let nativeId = "restart-unknown-exit-running-ctr"
        let ip = "192.168.65.93"
        let network = "myapp_default"

        let stoppedSnapshot = try unknownExitSnapshot(
            nativeId: nativeId, ip: ip, network: network, restartPolicyName: "on-failure", status: .stopped)
        let runningSnapshot = try unknownExitSnapshot(
            nativeId: nativeId, ip: ip, network: network, restartPolicyName: "on-failure", status: .running)
        let mock = UnknownExitMock(snapshot: stoppedSnapshot, postStartSnapshot: runningSnapshot)
        let dnsServer = SocktainerDNSServer()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(dnsServer.listEntries()[nativeId] == ip)

        await ContainerExitCodeStore.shared.set(id: nativeId, code: ContainerExitCodeStore.waitFailureSentinel)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(
            dnsServer.listEntries()[nativeId] == ip,
            "DNS aliases must not be removed when wait fails while the container is still running")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

}

// MARK: - Helpers

private func unknownExitSnapshot(
    nativeId: String, ip: String, network: String, restartPolicyName: String, status: RuntimeStatus = .stopped
) throws -> ContainerSnapshot {
    let policy = RestartPolicy(Name: restartPolicyName, MaximumRetryCount: nil)
    let policyJSON = String(data: try JSONEncoder().encode(policy), encoding: .utf8)!
    return try makeContainerSnapshot(
        nativeId: nativeId, ip: ip, network: network,
        labels: [RestartPolicyManager.label: policyJSON], status: status
    )
}

private actor UnknownExitMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot
    private let postStartSnapshot: ContainerSnapshot?
    private var startCalls = 0

    init(snapshot: ContainerSnapshot, postStartSnapshot: ContainerSnapshot? = nil) {
        self.snapshot = snapshot
        self.postStartSnapshot = postStartSnapshot
    }

    func startCallCount() -> Int { startCalls }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func prepareForStart(container: ContainerSnapshot) async throws {}
    func start(id: String, detachKeys: String?) async throws {
        startCalls += 1
        if let postStartSnapshot {
            snapshot = postStartSnapshot
        }
        // Mirrors ClientContainerService.startInternal: clear the previous run's code so
        // the newly-armed observer awaits the next exit instead of a stale one.
        await ContainerExitCodeStore.shared.remove(id: id)
    }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {
        if snapshot.status == .running {
            await ContainerRestartState.shared.markExplicitlyStopped(id: snapshot.id)
        }
        await ContainerExitCodeStore.shared.remove(id: id)
    }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func rename(id: String, newName: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
