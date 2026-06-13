import Foundation
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
    private static func waitForStatus(_ expected: String, on mgr: HealthCheckManager, id: String) async throws {
        for _ in 0..<600 {
            if await mgr.currentHealth(for: id)?.Status == expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
