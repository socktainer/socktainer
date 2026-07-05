import Foundation

/// Tracks per-container state needed to honor `HostConfig.RestartPolicy`: whether the last
/// exit followed an explicit stop/kill (which suppresses auto-restart) and how many restart
/// attempts have been made since the container was last started by the user.
actor ContainerRestartState {
    static let shared = ContainerRestartState()

    private var explicitlyStopped: Set<String> = []
    private var attempts: [String: Int] = [:]

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

    func reset(id: String) {
        explicitlyStopped.remove(id)
        attempts.removeValue(forKey: id)
    }
}
