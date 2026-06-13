import ContainerAPIClient
import Foundation
import Logging
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

        if startPeriodNs > 0 {
            try? await Task.sleep(nanoseconds: startPeriodNs)
        }

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

            if exitCode == 0 {
                failingStreak = 0
                updateStatus(id: containerId, health: ContainerHealth(Status: "healthy", FailingStreak: 0, Log: []), logEntry: entry)
            } else {
                failingStreak += 1
                let status = failingStreak >= maxRetries ? "unhealthy" : "starting"
                updateStatus(id: containerId, health: ContainerHealth(Status: status, FailingStreak: failingStreak, Log: []), logEntry: entry)
                log.debug("[healthcheck] \(containerId) → \(status) (streak=\(failingStreak), exit=\(exitCode))")
            }

            try? await Task.sleep(nanoseconds: intervalNs)
        }
    }

    private func runCheck(containerId: String, config: HealthcheckConfig, timeoutNs: UInt64) async -> Int32 {
        // nil means NONE / disabled / empty — do not mark the container healthy
        guard let cmd = Self.parseTest(config.Test) else { return 1 }
        return await probe(containerId, cmd, timeoutNs)
    }

    // MARK: - Default probe (real exec)

    private enum ProbeOutcome {
        case exited(Int32)
        case timedOut
    }

    /// Runs `cmd` inside the container via `createProcess`, with a timeout race.
    /// Returns the exit code, or 1 on any failure.
    static let execProbe: HealthProbe = { containerId, cmd, timeoutNs in
        do {
            let containerClient = ContainerClient()
            guard let container = try? await containerClient.get(id: containerId) else { return 1 }

            var processConfig = container.configuration.initProcess
            processConfig.executable = cmd[0]
            processConfig.arguments = Array(cmd.dropFirst())
            processConfig.terminal = false
            // Healthchecks run as root to avoid permission issues for probes
            // that need to bind sockets, read pidfiles, etc.
            processConfig.user = .id(uid: 0, gid: 0)

            let processId = "hc-\(UUID().uuidString.lowercased())"
            let process = try await containerClient.createProcess(
                containerId: containerId,
                processId: processId,
                configuration: processConfig,
                stdio: [nil, nil, nil]
            )
            try await process.start()

            let outcome: ProbeOutcome = try await withThrowingTaskGroup(of: ProbeOutcome.self) { group in
                group.addTask { .exited(try await process.wait()) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    return .timedOut
                }
                let result = try await group.next() ?? .timedOut
                group.cancelAll()
                return result
            }
            switch outcome {
            case .exited(let code):
                return code
            case .timedOut:
                try? await process.kill(SIGTERM)
                return 1
            }
        } catch {
            return 1
        }
    }
}
