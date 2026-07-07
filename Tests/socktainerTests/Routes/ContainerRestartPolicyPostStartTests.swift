import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests: an internal restart-policy-triggered restart used to call the bare
/// `client.start()` directly, skipping the DNS re-registration and `ContainerInfoCache` refresh
/// that a normal `/start` performs. A container that gets a new IP on restart would then keep
/// stale DNS entries and a stale cached IP. `observeExit` now routes its internal restart
/// through the same `ContainerStartRoute.performPostStartSetup` the HTTP handler uses.
@Suite("ContainerStartRoute — post-start setup on automatic restart")
struct ContainerRestartPolicyPostStartTests {

    @Test("An automatic restart re-registers DNS with the container's new IP")
    func automaticRestartRefreshesDNS() async throws {
        let nativeId = "restart-dns-refresh-ctr"
        let oldIP = "192.168.65.30"
        let newIP = "192.168.65.31"
        let network = "myapp_default"

        let mock = RestartMock(snapshot: try makeSnapshot(nativeId: nativeId, ip: oldIP, network: network, restartPolicyName: "always"))
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

        #expect(dnsServer.listEntries()[nativeId] == oldIP)

        // Simulate the restarted container coming up with a new IP (e.g. a fresh vmnet lease),
        // then trigger the "crash" that the always-policy observer will act on.
        await mock.setSnapshot(try makeSnapshot(nativeId: nativeId, ip: newIP, network: network, restartPolicyName: "always"))
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 1)

        let refreshed = try await pollUntil(timeoutSeconds: 3) {
            dnsServer.listEntries()[nativeId] == newIP
        }
        #expect(refreshed, "DNS entry must be refreshed to the new IP after an automatic restart")
        #expect(await ContainerInfoCache.shared.get(id: nativeId)?.ip == newIP, "ContainerInfoCache must also reflect the new IP")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("A manual /start during the backoff window supersedes the pending automatic restart")
    func manualStartDuringBackoffSupersedesPendingRestart() async throws {
        let nativeId = "restart-race-ctr"
        let ip = "192.168.65.40"
        let network = "myapp_default"

        let mock = RestartMock(snapshot: try makeSnapshot(nativeId: nativeId, ip: ip, network: network, restartPolicyName: "always"))
        let broadcaster = EventBroadcaster()
        let collector = EventCollector()
        let stream = await broadcaster.stream()
        let captureTask = Task {
            // event.id is the hex digest (DockerContainerID.hexId), not the raw native id — this
            // test only involves one container, so filtering on Action alone is unambiguous.
            for await event in stream where event.Action == "start" {
                await collector.add(event)
            }
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerStartRoute(client: mock))

            // Initial start — arms the first observeExit (generation 1).
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }

            // Crash: the observer decides to restart and enters its backoff sleep.
            await ContainerExitCodeStore.shared.set(id: nativeId, code: 1)
            let enteredBackoff = try await pollUntil(timeoutSeconds: 2) {
                await ContainerRestartState.shared.isPendingRestart(id: nativeId)
            }
            #expect(enteredBackoff, "observer must enter its backoff window before the race can be exercised")

            // RestartCount must not be bumped merely for deciding to restart — only once the
            // generation check right before client.start() confirms the restart will proceed.
            #expect(await ContainerRestartState.shared.count(id: nativeId) == 0, "attempt must not be recorded while still in the backoff window")

            // The user starts the container manually while the old observer is still sleeping —
            // this must supersede it (new generation) rather than race it.
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // Give the stale observer time to wake from its (100ms) backoff sleep and hit the
        // generation check — it must abort instead of calling client.start() a third time.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        captureTask.cancel()

        #expect(await mock.startCallCount() == 2, "the stale observer must not have called client.start() again")
        #expect(await collector.events.count == 2, "the stale observer must not have broadcast a spurious extra 'start' event")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("A redundant /start on an already-running container does not duplicate the next die event")
    func redundantStartOnRunningContainerDoesNotDuplicateDieEvent() async throws {
        let nativeId = "restart-redundant-start-ctr"
        let ip = "192.168.65.50"
        let network = "myapp_default"

        let stoppedSnapshot = try makeSnapshot(nativeId: nativeId, ip: ip, network: network, restartPolicyName: "no")
        let mock = RestartMock(snapshot: stoppedSnapshot)
        let broadcaster = EventBroadcaster()
        let collector = EventCollector()
        let stream = await broadcaster.stream()
        let captureTask = Task {
            for await event in stream where event.Action == "die" {
                await collector.add(event)
            }
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
            #expect(await mock.startCallCount() == 1)

            // Redundant /start on the now-running container: skips client.start() but still
            // bumps the generation and arms a second observer on the same nativeId.
            let runningSnapshot = try makeSnapshot(nativeId: nativeId, ip: ip, network: network, restartPolicyName: "no", status: .running)
            await mock.setSnapshot(runningSnapshot)
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
            #expect(await mock.startCallCount() == 1, "an already-running container must not call client.start() again")
        }

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)

        let sawDie = try await pollUntil(timeoutSeconds: 2) { await collector.events.count >= 1 }
        #expect(sawDie, "the current-generation observer must still broadcast its die event")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        captureTask.cancel()

        #expect(await collector.events.count == 1, "the stale observer must not have broadcast a duplicate 'die' event")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("A clean exit that on-failure declines to restart does not inflate RestartCount")
    func decliningToRestartDoesNotIncrementRestartCount() async throws {
        let nativeId = "restart-no-inflate-ctr"
        let ip = "192.168.65.60"
        let network = "myapp_default"

        let mock = RestartMock(snapshot: try makeSnapshot(nativeId: nativeId, ip: ip, network: network, restartPolicyName: "on-failure"))

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

        // on-failure never restarts on a clean exit — RestartCount must stay 0.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(await ContainerRestartState.shared.count(id: nativeId) == 0)

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("A manual /restart on an unless-stopped container still auto-restarts after a later crash")
    func manualRestartPreservesUnlessStoppedPolicy() async throws {
        let nativeId = "restart-unless-stopped-ctr"
        let ip = "192.168.65.70"
        let network = "myapp_default"

        let mock = RestartMock(snapshot: try makeSnapshot(nativeId: nativeId, ip: ip, network: network, restartPolicyName: "unless-stopped", status: .running))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerRestartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/restart") { res async in
                #expect(res.status == .noContent)
            }
        }

        // client.restart()'s internal stop step marks the container explicitly-stopped; the
        // manual-restart flow must clear that before this crash, or unless-stopped would
        // wrongly treat it as a user-initiated stop and never restart.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 1)

        let restarted = try await pollUntil(timeoutSeconds: 2) { await mock.startCallCount() >= 1 }
        #expect(restarted, "unless-stopped must still restart after a crash following a manual /restart")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }
}

private actor EventCollector {
    private(set) var events: [DockerEvent] = []
    func add(_ event: DockerEvent) { events.append(event) }
}

// MARK: - Helpers

private func makeSnapshot(nativeId: String, ip: String, network: String, restartPolicyName: String, status: RuntimeStatus = .stopped) throws -> ContainerSnapshot {
    let policy = RestartPolicy(Name: restartPolicyName, MaximumRetryCount: nil)
    let policyJSON = String(data: try JSONEncoder().encode(policy), encoding: .utf8)!
    return try makeContainerSnapshot(
        nativeId: nativeId, ip: ip, network: network,
        labels: [RestartPolicyManager.label: policyJSON], status: status
    )
}

private actor RestartMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot
    private var startCalls = 0

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func setSnapshot(_ snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func startCallCount() -> Int { startCalls }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {
        startCalls += 1
        // Mirrors ClientContainerService.startInternal, which clears any exit code recorded by
        // the previous run so the newly-armed observer awaits the *next* exit, not a stale one.
        await ContainerExitCodeStore.shared.remove(id: id)
    }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {
        // Mirrors ClientContainerService.restart(), which marks a running container
        // explicitly-stopped as part of its internal stop-then-start sequence.
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
