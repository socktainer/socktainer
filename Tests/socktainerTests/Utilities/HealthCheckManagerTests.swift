import ContainerResource
import Foundation
import Synchronization
import Testing

@testable import socktainer

@Suite("HealthCheckManager")
struct HealthCheckManagerTests {

    // MARK: - Test parsing (pure, no actor)

    @Test("CMD-SHELL wraps args in /bin/sh -c")
    func parseCmdShell() {
        #expect(HealthCheckManager.parseTest(["CMD-SHELL", "pg_isready -U postgres"]) == ["/bin/sh", "-c", "pg_isready -U postgres"])
    }

    @Test("CMD passes args through directly")
    func parseCmd() {
        #expect(HealthCheckManager.parseTest(["CMD", "pg_isready", "-U", "postgres"]) == ["pg_isready", "-U", "postgres"])
    }

    @Test("NONE disables the check")
    func parseNone() {
        #expect(HealthCheckManager.parseTest(["NONE"]) == nil)
    }

    // MARK: - Image healthcheck inheritance (#417)

    private static let imageCheck = HealthcheckConfig(
        Test: ["CMD", "python", "/app/healthcheck.py"], Interval: 1_000_000_000, Timeout: 10_000_000_000, Retries: 3,
        StartPeriod: 5_000_000_000, StartInterval: 500_000_000)

    @Test("omitted request inherits the image healthcheck")
    func mergeInheritsImage() {
        let merged = HealthcheckConfig.merged(request: nil, image: Self.imageCheck)
        #expect(merged?.Test == ["CMD", "python", "/app/healthcheck.py"])
        #expect(merged?.Interval == 1_000_000_000)
        #expect(merged?.Retries == 3)
    }

    @Test("unset request fields fall back to the image's")
    func mergePartialOverride() {
        let request = HealthcheckConfig(Test: [], Interval: 2_000_000_000, Timeout: 0, Retries: nil, StartPeriod: nil)
        let merged = HealthcheckConfig.merged(request: request, image: Self.imageCheck)
        #expect(merged?.Test == ["CMD", "python", "/app/healthcheck.py"])
        #expect(merged?.Interval == 2_000_000_000)
        #expect(merged?.Timeout == 10_000_000_000)
        #expect(merged?.Retries == 3)
        #expect(merged?.StartPeriod == 5_000_000_000)
        #expect(merged?.StartInterval == 500_000_000)
    }

    @Test("NONE request disables an image healthcheck")
    func mergeNoneDisables() {
        let request = HealthcheckConfig(Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil)
        let merged = HealthcheckConfig.merged(request: request, image: Self.imageCheck)
        #expect(merged?.Test == ["NONE"])
        #expect(HealthCheckManager.parseTest(merged?.Test) == nil)
    }

    @Test("no request and no image healthcheck yields none")
    func mergeNothing() {
        #expect(HealthcheckConfig.merged(request: nil, image: nil) == nil)
    }

    @Test("Bare test (no CMD prefix) runs as-is")
    func parseBare() {
        #expect(HealthCheckManager.parseTest(["pg_isready"]) == ["pg_isready"])
    }

    @Test("Empty or nil test returns nil")
    func parseEmpty() {
        #expect(HealthCheckManager.parseTest(nil) == nil)
        #expect(HealthCheckManager.parseTest([]) == nil)
    }

    @Test("CMD with no following args returns nil (avoids exec of empty cmd)")
    func parseCmdWithoutArgs() {
        #expect(HealthCheckManager.parseTest(["CMD"]) == nil)
    }

    // MARK: - Lifecycle

    @Test("currentHealth is nil before start")
    func notRunningInitially() async {
        let mgr = HealthCheckManager()
        let h = await mgr.currentHealth(for: "c1")
        #expect(h == nil)
    }

    @Test("stop clears status")
    func stopClearsStatus() async {
        // Probe never returns within the test window — we just want a quick
        // start-then-stop to validate state is wiped.
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        #expect(await mgr.currentHealth(for: "c1") != nil)
        await mgr.stop(containerId: "c1")
        #expect(await mgr.currentHealth(for: "c1") == nil)
    }

    @Test("start is idempotent")
    func startIdempotent() async {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        let firstStatus = await mgr.currentHealth(for: "c1")
        await mgr.start(containerId: "c1", config: cfg)  // second call no-ops
        let secondStatus = await mgr.currentHealth(for: "c1")
        #expect(firstStatus?.Status == "starting")
        #expect(secondStatus?.Status == "starting")
        await mgr.stop(containerId: "c1")
    }

    // MARK: - State transitions

    @Test("First successful probe transitions to healthy")
    func healthyOnFirstSuccess() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect(h?.Status == "healthy")
        #expect(h?.FailingStreak == 0)
        await mgr.stop(containerId: "c1")
    }

    @Test("Persistent failures transition to unhealthy after Retries")
    func unhealthyAfterRetries() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 2, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("unhealthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect(h?.Status == "unhealthy")
        #expect((h?.FailingStreak ?? 0) >= 2)
        await mgr.stop(containerId: "c1")
    }

    @Test("StartInterval probes during StartPeriod instead of waiting it out")
    func startIntervalProbesDuringStartPeriod() async throws {
        let mgr = HealthCheckManager(probe: { _, _, _ in 0 }, intervalFloorNs: 1_000_000)
        let cfg = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3,
            StartPeriod: 60_000_000_000, StartInterval: 1_000_000)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        await mgr.stop(containerId: "c1")
    }

    @Test("Without StartInterval, StartPeriod is probed at Docker's default cadence, not waited out")
    func defaultStartIntervalProbesDuringStartPeriod() async throws {
        let mgr = HealthCheckManager(probe: { _, _, _ in 0 }, intervalFloorNs: 1_000_000)
        let cfg = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: 60_000_000_000)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        await mgr.stop(containerId: "c1")
    }

    @Test("Failures during StartPeriod don't count toward Retries")
    func startPeriodFailuresIgnored() async throws {
        let mgr = HealthCheckManager(probe: { _, _, _ in 1 }, intervalFloorNs: 1_000_000)
        let cfg = HealthcheckConfig(
            Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 1,
            StartPeriod: 60_000_000_000, StartInterval: 1_000_000)
        await mgr.start(containerId: "c1", config: cfg)
        for _ in 0..<600 where (await mgr.currentHealth(for: "c1")?.Log.count ?? 0) < 3 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) >= 3)
        #expect(h?.Status == "starting")
        #expect(h?.FailingStreak == 0)
        await mgr.stop(containerId: "c1")
    }

    @Test("A failure below Retries keeps a healthy container healthy")
    func healthyStaysHealthyBelowRetries() async throws {
        actor Calls {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let calls = Calls()
        let mgr = HealthCheckManager(
            probe: { _, _, _ in await calls.next() == 1 ? 0 : 1 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 1_000, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        for _ in 0..<600 where (await mgr.currentHealth(for: "c1")?.FailingStreak ?? 0) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.FailingStreak ?? 0) >= 2)
        #expect(h?.Status == "healthy")
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Probe process

    @Test("Probe runs as the container's configured user, not root")
    func probeKeepsContainerUser() {
        let base = ProcessConfiguration(
            executable: "/entrypoint.sh", arguments: ["serve"], environment: ["A=1"],
            workingDirectory: "/app", terminal: true, user: .raw(userString: "501:20")
        )
        let probe = HealthCheckManager.probeProcessConfiguration(base: base, cmd: ["/bin/sh", "-c", "/healthcheck.sh"])
        #expect(probe.user == .raw(userString: "501:20"))
        #expect(probe.executable == "/bin/sh")
        #expect(probe.arguments == ["-c", "/healthcheck.sh"])
        #expect(probe.terminal == false)
        #expect(probe.environment == ["A=1"])
        #expect(probe.workingDirectory == "/app")
    }

    // These check that waitForProbe returns while the stalled call is still unreleased,
    // rather than timing it, so a slow runner can't fail them.
    @Test("A probe that outlives Timeout fails and is signalled at the deadline, though wait() ignores cancellation")
    func probeTimeoutDoesNotWaitForWait() async {
        let stalledWait = StalledCall()
        let killed = KillFlag()
        let code = await HealthCheckManager.waitForProbe(
            timeoutNs: 50_000_000,
            wait: {
                await stalledWait.call()
                return 0
            },
            kill: { killed.set() }
        )
        let returnedWhileStalled = !stalledWait.isReleased
        let waitWasCalled = await stalledWait.waitUntilCalled()
        stalledWait.release()
        #expect(code == 1)
        #expect(killed.isSet)
        #expect(waitWasCalled)
        #expect(returnedWhileStalled, "waitForProbe waited for wait() past the deadline")
    }

    @Test("A probe that exits within Timeout returns its exit code and is not killed")
    func probeExitWithinTimeout() async {
        let killed = KillFlag()
        let code = await HealthCheckManager.waitForProbe(
            timeoutNs: 5_000_000_000,
            wait: { 3 },
            kill: { killed.set() }
        )
        #expect(code == 3)
        #expect(!killed.isSet)
    }

    @Test("A kill that stalls at the deadline doesn't hold the loop either")
    func stalledKillIsBounded() async {
        let stalledWait = StalledCall()
        let stalledKill = StalledCall()
        let code = await HealthCheckManager.waitForProbe(
            timeoutNs: 50_000_000,
            wait: {
                await stalledWait.call()
                return 0
            },
            kill: { await stalledKill.call() }
        )
        let returnedWhileStalled = !stalledKill.isReleased
        let killWasCalled = await stalledKill.waitUntilCalled()
        stalledWait.release()
        stalledKill.release()
        #expect(code == 1)
        #expect(killWasCalled)
        #expect(returnedWhileStalled, "waitForProbe waited for kill() past its limit")
    }

    @Test("While a timed-out probe is still running, the next one fails without starting another process")
    func noSecondProbeWhileOneIsRunning() async {
        let inFlight = HealthCheckManager.ProbesInFlight()
        let stalledWait = StalledCall()
        let starts = StartCounter()
        let stalledStart: () async throws -> HealthCheckManager.StartedProbe = {
            starts.increment()
            return (
                wait: {
                    await stalledWait.call()
                    return 0
                },
                kill: {}
            )
        }
        let first = await HealthCheckManager.runProbe(containerId: "c1", timeoutNs: 50_000_000, inFlight: inFlight, start: stalledStart)
        let second = await HealthCheckManager.runProbe(containerId: "c1", timeoutNs: 50_000_000, inFlight: inFlight, start: stalledStart)
        #expect(first == 1)
        #expect(second == 1)
        #expect(starts.count == 1, "a second probe process started beside the stuck one")

        let otherContainer = await HealthCheckManager.runProbe(containerId: "c2", timeoutNs: 5_000_000_000, inFlight: inFlight) {
            (wait: { 0 }, kill: {})
        }
        #expect(otherContainer == 0)

        stalledWait.release()
        for _ in 0..<300 where inFlight.isRunning("c1") {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let afterExit = await HealthCheckManager.runProbe(containerId: "c1", timeoutNs: 5_000_000_000, inFlight: inFlight) {
            (wait: { 0 }, kill: {})
        }
        #expect(afterExit == 0)
    }

    @Test("A probe that fails to start doesn't block the next one")
    func failedStartFreesTheContainer() async {
        struct StartFailed: Error {}
        let inFlight = HealthCheckManager.ProbesInFlight()
        let failed = await HealthCheckManager.runProbe(containerId: "c1", timeoutNs: 5_000_000_000, inFlight: inFlight) {
            throw StartFailed()
        }
        let next = await HealthCheckManager.runProbe(containerId: "c1", timeoutNs: 5_000_000_000, inFlight: inFlight) {
            (wait: { 0 }, kill: {})
        }
        #expect(failed == 1)
        #expect(next == 0)
    }

    private final class StartCounter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    private final class KillFlag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// Stands in for an XPC call that ignores cancellation: `call()` returns only once
    /// released, by the test or by a fallback far beyond any deadline under test.
    private final class StalledCall: Sendable {
        private let state = Mutex<(called: Bool, released: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, false, []))

        init(fallback: Duration = .seconds(30)) {
            Task.detached { [self] in
                try? await Task.sleep(for: fallback)
                self.release()
            }
        }

        var isReleased: Bool { state.withLock { $0.released } }

        /// Waits, up to 30 s, for `call()` to be entered: the callback runs in a detached
        /// task that a loaded runner may not have started by the time `waitForProbe` returns.
        func waitUntilCalled() async -> Bool {
            for _ in 0..<300 where !state.withLock({ $0.called }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return state.withLock { $0.called }
        }

        func call() async {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    state.called = true
                    if state.released { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.released = true
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    // MARK: - Health log entries

    @Test("Log entries are recorded after each probe")
    func logEntriesRecorded() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) > 0)
        #expect(h?.Log.first?.ExitCode == 0)
        #expect(h?.Log.first?.Start.isEmpty == false)
        await mgr.stop(containerId: "c1")
    }

    @Test("Log is capped at 5 entries")
    func logCappedAt5() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        // Wait long enough for >5 probe calls at 1ms interval
        try await Task.sleep(nanoseconds: 30_000_000)
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) <= 5)
        await mgr.stop(containerId: "c1")
    }

    // MARK: - health_status events

    @Test("health_status events are emitted on status transition to healthy")
    func healthStatusEventsEmitted() async throws {
        actor Collector {
            var statuses: [String] = []
            func append(_ s: String) { statuses.append(s) }
        }
        let collector = Collector()
        let broadcaster = EventBroadcaster()

        let collectTask = Task { @Sendable in
            for await event in await broadcaster.stream() {
                if event.status.hasPrefix("health_status:") {
                    await collector.append(event.status)
                }
                if await collector.statuses.count >= 1 { break }
            }
        }

        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000,
            broadcaster: broadcaster
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        try await Task.sleep(nanoseconds: 20_000_000)
        collectTask.cancel()
        await mgr.stop(containerId: "c1")

        let received = await collector.statuses
        #expect(received.contains("health_status: healthy"))
    }

    // MARK: - Log entry detail for failing probe

    @Test("Log entry records non-zero exit code on failure")
    func logEntryForFailingProbe() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },  // always fail
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 1, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("unhealthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) > 0)
        #expect(h?.Log.first?.ExitCode == 1)
        await mgr.stop(containerId: "c1")
    }

    @Test("Log entry Start and End are non-empty ISO8601 strings")
    func logEntryTimestampsAreISO8601() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        guard let entry = h?.Log.first else {
            Issue.record("No log entries")
            return
        }
        // ISO8601 with fractional seconds: e.g. "2026-06-13T01:23:45.678Z"
        #expect(entry.Start.contains("T"))
        #expect(entry.Start.contains("Z"))
        #expect(entry.End.contains("T"))
        // End must be >= Start (both valid timestamps)
        let start = ISO8601DateFormatter().date(from: entry.Start)
        let end = ISO8601DateFormatter().date(from: entry.End)
        if let s = start, let e = end {
            #expect(e >= s)
        }
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Helpers

    /// Polls every 5ms up to ~3s for the manager to report `expected` status.
    /// Fails the test if the status is never reached.
    private static func waitForStatus(_ expected: String, on mgr: HealthCheckManager, id: String) async throws {
        for _ in 0..<600 {
            if await mgr.currentHealth(for: id)?.Status == expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let actual = await mgr.currentHealth(for: id)?.Status
        Issue.record("waitForStatus timed out: expected '\(expected)' but got '\(actual ?? "nil")' for container '\(id)'")
        struct TimeoutError: Error {}
        throw TimeoutError()
    }
}
