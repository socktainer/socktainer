import Foundation

enum RestartPolicyManager {
    static let label = "socktainer.restart-policy"

    static func decode(from labels: [String: String]) -> RestartPolicy? {
        guard let json = labels[label], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RestartPolicy.self, from: data)
    }

    /// Mirrors moby's `RestartPolicy.ValidateRestartPolicy` (api/types/container/hostconfig.go, v28.5.2).
    static func validate(hostConfig: HostConfig?) -> String? {
        guard let policy = hostConfig?.RestartPolicy else { return nil }
        let isNone = policy.Name == "no" || policy.Name == ""

        if hostConfig?.AutoRemove == true, !isNone {
            return "can't create 'AutoRemove' container with restart policy"
        }

        return validatePolicy(policy)
    }

    static func validatePolicy(_ policy: RestartPolicy) -> String? {
        switch policy.Name {
        case "always", "unless-stopped", "no":
            if let maxRetryCount = policy.MaximumRetryCount, maxRetryCount != 0 {
                var message = "invalid restart policy: maximum retry count can only be used with 'on-failure'"
                if maxRetryCount < 0 {
                    message += " and cannot be negative"
                }
                return message
            }
            return nil
        case "on-failure":
            if let maxRetryCount = policy.MaximumRetryCount, maxRetryCount < 0 {
                return "invalid restart policy: maximum retry count cannot be negative"
            }
            return nil
        case "":
            return nil
        default:
            return "invalid restart policy: unknown policy '\(policy.Name)'; use one of 'no', 'always', 'on-failure', or 'unless-stopped'"
        }
    }

    /// `always` restarts even after an explicit stop/kill; only `unless-stopped` honors
    /// `hasBeenManuallyStopped`. Matches moby's documented gotcha — restartmanager.go, v28.5.2.
    static func shouldRestart(policy: RestartPolicy, exitCode: Int32, attempt: Int, hasBeenManuallyStopped: Bool) -> Bool {
        switch policy.Name {
        case "always":
            return true
        case "unless-stopped":
            return !hasBeenManuallyStopped
        case "on-failure":
            guard exitCode != 0 else { return false }
            let maxRetries = policy.MaximumRetryCount ?? 0
            return maxRetries <= 0 || attempt <= maxRetries
        default:
            return false
        }
    }

    /// Doubles per rapid crash (100ms base, 1 minute cap); resets to base once the container ran
    /// 10+ seconds. Mirrors moby's `RestartManager.ShouldRestart` timeout math, v28.5.2.
    static func nextBackoffMillis(current: UInt64, ranAtLeast10Seconds: Bool) -> UInt64 {
        let baseMillis: UInt64 = 100
        let capMillis: UInt64 = 60_000
        let previous = ranAtLeast10Seconds ? 0 : current
        return previous == 0 ? baseMillis : min(capMillis, previous * 2)
    }
}
