import Foundation

/// Tracks per-container state needed to honor `HostConfig.RestartPolicy`: whether the last
/// exit followed an explicit stop/kill (which suppresses auto-restart) and how many restart
/// attempts have been made since the container was last started by the user.
actor ContainerRestartState {
    static let shared = ContainerRestartState()

    private var explicitlyStopped: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var pendingRestart: Set<String> = []
    private var backoffMillis: [String: UInt64] = [:]
    private var generation: [String: Int] = [:]

    func markExplicitlyStopped(id: String) {
        explicitlyStopped.insert(id)
    }

    func consumeExplicitlyStopped(id: String) -> Bool {
        explicitlyStopped.remove(id) != nil
    }

    func nextAttempt(id: String) -> Int {
        let next = (attempts[id] ?? 0) + 1
        attempts[id] = next
        return next
    }

    func count(id: String) -> Int {
        attempts[id] ?? 0
    }

    func markPendingRestart(id: String) {
        pendingRestart.insert(id)
    }

    func clearPendingRestart(id: String) {
        pendingRestart.remove(id)
    }

    func isPendingRestart(id: String) -> Bool {
        pendingRestart.contains(id)
    }

    func nextBackoffDelayNanoseconds(id: String, ranAtLeast10Seconds: Bool) -> UInt64 {
        let next = RestartPolicyManager.nextBackoffMillis(current: backoffMillis[id] ?? 0, ranAtLeast10Seconds: ranAtLeast10Seconds)
        backoffMillis[id] = next
        return next * 1_000_000
    }

    /// Whether `generation` still matches this container's current lifecycle. A backoff-sleeping
    /// `observeExit` task checks this before acting, so a `reset(id:)` that ran while it slept
    /// (a newer `/start` or a delete) makes it a no-op instead of a duplicate observer.
    func isCurrent(id: String, generation: Int) -> Bool {
        self.generation[id, default: 0] == generation
    }

    func currentGeneration(id: String) -> Int {
        generation[id] ?? 0
    }

    /// Starts a fresh restart-policy lifecycle for a container: clears its explicit-stop flag,
    /// attempt count, pending-restart flag, and backoff state, and bumps its generation token.
    /// Called on every user-driven `/start` and on delete.
    func reset(id: String) {
        explicitlyStopped.remove(id)
        attempts.removeValue(forKey: id)
        pendingRestart.remove(id)
        backoffMillis.removeValue(forKey: id)
        generation[id] = (generation[id] ?? 0) + 1
    }
}
