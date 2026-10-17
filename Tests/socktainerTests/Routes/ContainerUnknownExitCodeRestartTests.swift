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
        // The guard on unknown status must not disable the policy itself.
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
    private var startCalls = 0

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func startCallCount() -> Int { startCalls }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {
        startCalls += 1
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
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
