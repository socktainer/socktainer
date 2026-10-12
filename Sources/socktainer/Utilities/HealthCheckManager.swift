import ContainerAPIClient
import ContainerResource
import Foundation
import Logging
import Synchronization
import Vapor

struct HealthCheckManagerKey: StorageKey {
    typealias Value = HealthCheckManager
}

/// A function that runs a healthcheck command inside a container and returns
/// its exit code. Injected so tests can stub the side-effecting exec path.
typealias HealthProbe = @Sendable (_ containerId: String, _ cmd: [String], _ timeoutNs: UInt64) async -> Int32

/// Runs Docker `HEALTHCHECK` probes inside containers and tracks their status.
///
/// Apple Container 1.0.0 has no native runtime healthcheck support, so we
/// implement it here: when a container is started, we periodically exec the
/// configured test command via `ContainerClient.createProcess` and record the
/// outcome. `GET /containers/{id}/json` reads from this manager to populate
/// `.State.Health`, which Docker clients (e.g. Supabase CLI, Compose
/// `depends_on: service_healthy`) gate on.
///
/// The probe config is persisted across `create → start` as a JSON-encoded
/// label (`socktainer.healthcheck`) on the container, so the manager can
/// rebuild the loop on each start without holding pre-start state itself.
actor HealthCheckManager {
    static let healthcheckLabel = "socktainer.healthcheck"

    // Docker's documented defaults when the field is absent from the request.
    // See https://docs.docker.com/reference/dockerfile/#healthcheck.
    static let defaultIntervalNs: UInt64 = 30 * 1_000_000_000
    static let defaultTimeoutNs: UInt64 = 30 * 1_000_000_000
    static let defaultRetries: Int = 3
    static let defaultStartIntervalNs: UInt64 = 5 * 1_000_000_000

    // Lower bounds applied to the user-supplied values. The interval floor is
    // overridable so tests can drive the loop at sub-second cadence; the
    // timeout floor stays fixed because there's no test scenario where we
    // want a sub-second timeout on a real exec.
    static let defaultMinimumIntervalNs: UInt64 = 1_000_000_000
    static let minimumTimeoutNs: UInt64 = 1_000_000_000

    private var statuses: [String: ContainerHealth] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var logs: [String: [HealthLogEntry]] = [:]  // ring buffer, max 5 entries per container
    private let log = Logger(label: "socktainer.healthcheck")
    private let probe: HealthProbe
    private let intervalFloorNs: UInt64
    /// Optional broadcaster for Docker `health_status` events. Nil in tests.
    private let broadcaster: EventBroadcaster?

    private static let maxLogEntries = 5

    private static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    init(probe: @escaping HealthProbe = HealthCheckManager.execProbe, intervalFloorNs: UInt64 = HealthCheckManager.defaultMinimumIntervalNs, broadcaster: EventBroadcaster? = nil) {
        self.probe = probe
        self.intervalFloorNs = intervalFloorNs
        self.broadcaster = broadcaster
    }

    func currentHealth(for id: String) -> ContainerHealth? {
        guard let status = statuses[id] else { return nil }
        return ContainerHealth(Status: status.Status, FailingStreak: status.FailingStreak, Log: logs[id] ?? [])
    }

    /// Start running healthchecks for a container. No-op if already running or if the
    /// test is disabled (`NONE`, empty, or bare `CMD` with no arguments).
    func start(containerId: String, config: HealthcheckConfig) {
        guard Self.parseTest(config.Test) != nil else { return }
        guard tasks[containerId] == nil else { return }
        statuses[containerId] = ContainerHealth(Status: "starting", FailingStreak: 0, Log: [])
        let task = Task { [self] in
            await self.runLoop(containerId: containerId, config: config)
        }
        tasks[containerId] = task
        log.info("[healthcheck] started for \(containerId)")
    }

    /// Stop the healthcheck loop for a container.
    func stop(containerId: String) {
        tasks.removeValue(forKey: containerId)?.cancel()
        statuses.removeValue(forKey: containerId)
        logs.removeValue(forKey: containerId)
    }

    /// Parses Docker's `Test` field into a runnable command vector.
    /// Returns nil for empty input or `["NONE"]` (the disable sentinel).
    static func parseTest(_ test: [String]?) -> [String]? {
        guard let test, !test.isEmpty else { return nil }
        switch test.first {
        case "NONE":
            return nil
        case "CMD-SHELL":
            return ["/bin/sh", "-c", test.dropFirst().joined(separator: " ")]
        case "CMD":
            let args = Array(test.dropFirst())
            return args.isEmpty ? nil : args
        default:
            return test
        }
    }

    // MARK: - Private

    private func updateStatus(id: String, health: ContainerHealth, logEntry: HealthLogEntry? = nil) {
        guard tasks[id] != nil else { return }  // already stopped
        let previous = statuses[id]?.Status
        statuses[id] = health
        if let entry = logEntry {
            var entries = logs[id] ?? []
            entries.append(entry)
            if entries.count > Self.maxLogEntries {
                entries.removeFirst(entries.count - Self.maxLogEntries)
            }
            logs[id] = entries
        }
        // Emit Docker health_status event on every transition (including starting → healthy).
        if previous != health.Status, let broadcaster {
            Task {
                let event = DockerEvent.simpleEvent(
                    id: id, type: "container",
                    status: "health_status: \(health.Status)"
                )
                await broadcaster.broadcast(event)
            }
        }
    }

    private func isActive(id: String) -> Bool {
        tasks[id] != nil
    }

    private func runLoop(containerId: String, config: HealthcheckConfig) async {
        // Intervals on the Docker API are nanoseconds.
        let startPeriodNs = UInt64(max(config.StartPeriod ?? 0, 0))
        let configIntervalNs = config.Interval.map { UInt64(max($0, 0)) } ?? Self.defaultIntervalNs
        let intervalNs = max(configIntervalNs, intervalFloorNs)
        let configTimeoutNs = config.Timeout.map { UInt64(max($0, 0)) } ?? Self.defaultTimeoutNs
        let timeoutNs = max(configTimeoutNs, Self.minimumTimeoutNs)
        let maxRetries = config.Retries ?? Self.defaultRetries

        let configStartIntervalNs = config.StartInterval.map { UInt64(max($0, 0)) } ?? 0
        let startIntervalNs = max(configStartIntervalNs > 0 ? configStartIntervalNs : Self.defaultStartIntervalNs, intervalFloorNs)

        // Like Docker, probe every StartInterval during StartPeriod rather than waiting it out.
        var startDeadline: Date? =
            startPeriodNs > 0 ? Date().addingTimeInterval(Double(startPeriodNs) / 1_000_000_000) : nil

        var failingStreak = 0

        while !Task.isCancelled {
            guard isActive(id: containerId) else { return }

            let start = Date()
            let exitCode = await runCheck(containerId: containerId, config: config, timeoutNs: timeoutNs)
            let end = Date()

            guard !Task.isCancelled else { return }

            let entry = HealthLogEntry(
                Start: Self.formatISO8601(start),
                End: Self.formatISO8601(end),
                ExitCode: exitCode,
                Output: ""  // stdout capture from container VMs requires pipe infrastructure
            )

            let inStartPeriod = startDeadline.map { start < $0 } ?? false  // classify by when the probe began

            if exitCode == 0 {
                startDeadline = nil  // the first success ends the start period
                failingStreak = 0
                updateStatus(id: containerId, health: ContainerHealth(Status: "healthy", FailingStreak: 0, Log: []), logEntry: entry)
            } else if inStartPeriod {
                // Failures during the start period don't count toward Retries.
                updateStatus(id: containerId, health: ContainerHealth(Status: "starting", FailingStreak: 0, Log: []), logEntry: entry)
            } else {
                failingStreak += 1
                // Below Retries, keep the current status: a healthy container stays healthy.
                let status = failingStreak >= maxRetries ? "unhealthy" : (statuses[containerId]?.Status ?? "starting")
                updateStatus(id: containerId, health: ContainerHealth(Status: status, FailingStreak: failingStreak, Log: []), logEntry: entry)
                log.debug("[healthcheck] \(containerId) → \(status) (streak=\(failingStreak), exit=\(exitCode))")
            }

            let stillStarting = startDeadline.map { Date() < $0 } ?? false
            try? await Task.sleep(nanoseconds: stillStarting ? startIntervalNs : intervalNs)
        }
    }

    private func runCheck(containerId: String, config: HealthcheckConfig, timeoutNs: UInt64) async -> Int32 {
        // nil means NONE / disabled / empty — do not mark the container healthy
        guard let cmd = Self.parseTest(config.Test) else { return 1 }
        return await probe(containerId, cmd, timeoutNs)
    }

    // MARK: - Default probe (real exec)

    /// Builds the probe's process from the container's init process. Like Docker,
    /// the probe keeps the container's configured user (as `docker exec` without
    /// `-u` does): a root probe leaves root-owned files, such as a marker in sticky
    /// `/tmp`, that the container's own user can then no longer remove.
    static func probeProcessConfiguration(base: ProcessConfiguration, cmd: [String]) -> ProcessConfiguration {
        var processConfig = base
        processConfig.executable = cmd[0]
        processConfig.arguments = Array(cmd.dropFirst())
        processConfig.terminal = false
        return processConfig
    }

    /// How long the health loop waits for `kill` at the probe deadline before moving on.
    static let probeKillTimeout: Duration = .seconds(1)

    /// Waits up to `timeoutNs` for the probe to exit, returning its exit code, or 1
    /// after calling `kill` at the deadline. `wait` and `kill` are XPC calls that ignore
    /// task cancellation, so they can't be raced in a task group, which waits for every
    /// child before returning; they run under the startup housekeeping deadline instead.
    static func waitForProbe(
        timeoutNs: UInt64,
        wait: @escaping @Sendable () async throws -> Int32,
        kill: @escaping @Sendable () async -> Void
    ) async -> Int32 {
        let exitCode = ProbeExitCode()
        let exited = await StartupHousekeeping.runBounded(timeout: .nanoseconds(timeoutNs)) {
            let code = (try? await wait()) ?? 1
            exitCode.value.withLock { $0 = code }
        }
        guard exited else {
            _ = await StartupHousekeeping.runBounded(timeout: probeKillTimeout) { await kill() }
            return 1
        }
        return exitCode.value.withLock { $0 }
    }

    private final class ProbeExitCode: Sendable {
        let value = Mutex<Int32>(1)
    }

    /// Containers with a probe still running. A timed-out probe's kill can fail
    /// (apple/container#1941), so a later probe for that container fails at once rather
    /// than start another process beside it, until the first one exits.
    final class ProbesInFlight: Sendable {
        private let ids = Mutex<Set<String>>([])
        func begin(_ id: String) -> Bool { ids.withLock { $0.insert(id).inserted } }
        func end(_ id: String) { ids.withLock { _ = $0.remove(id) } }
        func isRunning(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
    }

    static let probesInFlight = ProbesInFlight()

    typealias StartedProbe = (wait: @Sendable () async throws -> Int32, kill: @Sendable () async -> Void)

    /// Starts a probe with `start` and waits for it, or returns 1 without starting one
    /// while the container's previous probe is still running.
    static func runProbe(
        containerId: String,
        timeoutNs: UInt64,
        inFlight: ProbesInFlight,
        start: () async throws -> StartedProbe
    ) async -> Int32 {
        guard inFlight.begin(containerId) else { return 1 }
        let probe: StartedProbe
        do {
            probe = try await start()
        } catch {
            inFlight.end(containerId)
            return 1
        }
        return await waitForProbe(
            timeoutNs: timeoutNs,
            wait: {
                defer { inFlight.end(containerId) }
                return try await probe.wait()
            },
            kill: probe.kill
        )
    }

    /// Runs `cmd` inside the container via `createProcess`, with a timeout race.
    /// Returns the exit code, or 1 on any failure.
    static let execProbe: HealthProbe = { containerId, cmd, timeoutNs in
        await runProbe(containerId: containerId, timeoutNs: timeoutNs, inFlight: probesInFlight) {
            let containerClient = ContainerClient()
            let container = try await containerClient.get(id: containerId)

            let processConfig = probeProcessConfiguration(base: container.configuration.initProcess, cmd: cmd)
            let processId = "hc-\(UUID().uuidString.lowercased())"
            let process = try await containerClient.createProcess(
                containerId: containerId,
                processId: processId,
                configuration: processConfig,
                stdio: [nil, nil, nil]
            )
            try await process.start()
            return (wait: { try await process.wait() }, kill: { try? await process.kill(SIGTERM) })
        }
    }
}
