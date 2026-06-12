import ContainerAPIClient
import Foundation
import Logging
import Vapor

struct HealthCheckManagerKey: StorageKey {
    typealias Value = HealthCheckManager
}

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

    private var statuses: [String: ContainerHealth] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let log = Logger(label: "socktainer.healthcheck")

    func currentHealth(for id: String) -> ContainerHealth? {
        statuses[id]
    }

    /// Start running healthchecks for a container. No-op if already running.
    func start(containerId: String, config: HealthcheckConfig) {
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
    }

    // MARK: - Private

    private func updateStatus(id: String, health: ContainerHealth) {
        guard tasks[id] != nil else { return }  // already stopped
        statuses[id] = health
    }

    private func isActive(id: String) -> Bool {
        tasks[id] != nil
    }

    private func runLoop(containerId: String, config: HealthcheckConfig) async {
        // Intervals on the Docker API are nanoseconds.
        let startPeriodNs = UInt64(max((config.StartPeriod ?? 0), 0))
        let intervalNs = UInt64(max((config.Interval ?? 30_000_000_000), 1_000_000_000))
        let timeoutNs = UInt64(max((config.Timeout ?? 30_000_000_000), 1_000_000_000))
        let maxRetries = config.Retries ?? 3

        if startPeriodNs > 0 {
            try? await Task.sleep(nanoseconds: startPeriodNs)
        }

        var failingStreak = 0

        while !Task.isCancelled {
            guard isActive(id: containerId) else { return }

            let exitCode = await runCheck(containerId: containerId, config: config, timeoutNs: timeoutNs)

            guard !Task.isCancelled else { return }

            if exitCode == 0 {
                failingStreak = 0
                updateStatus(id: containerId, health: ContainerHealth(Status: "healthy", FailingStreak: 0, Log: []))
            } else {
                failingStreak += 1
                let status = failingStreak >= maxRetries ? "unhealthy" : "starting"
                updateStatus(id: containerId, health: ContainerHealth(Status: status, FailingStreak: failingStreak, Log: []))
                log.debug("[healthcheck] \(containerId) → \(status) (streak=\(failingStreak), exit=\(exitCode))")
            }

            try? await Task.sleep(nanoseconds: intervalNs)
        }
    }

    private func runCheck(containerId: String, config: HealthcheckConfig, timeoutNs: UInt64) async -> Int32 {
        guard let test = config.Test, !test.isEmpty else { return 0 }

        // Docker spec: ["NONE"] disables an inherited check, ["CMD", ...] runs
        // the args directly, ["CMD-SHELL", ...] wraps in /bin/sh -c.
        let cmd: [String]
        switch test.first {
        case "NONE":
            return 0
        case "CMD-SHELL":
            cmd = ["/bin/sh", "-c", test.dropFirst().joined(separator: " ")]
        case "CMD":
            cmd = Array(test.dropFirst())
        default:
            cmd = test
        }
        guard !cmd.isEmpty else { return 0 }

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

            return try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { try await process.wait() }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    return 1
                }
                let result = try await group.next() ?? 1
                group.cancelAll()
                return result
            }
        } catch {
            log.debug("[healthcheck] \(containerId) exec error: \(error)")
            return 1
        }
    }
}
