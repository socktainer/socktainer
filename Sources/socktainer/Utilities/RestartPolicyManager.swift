import Foundation

enum RestartPolicyManager {
    static let label = "socktainer.restart-policy"

    static func decode(from labels: [String: String]) -> RestartPolicy? {
        guard let json = labels[label], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RestartPolicy.self, from: data)
    }

    static func shouldRestart(policy: RestartPolicy, exitCode: Int32, attempt: Int) -> Bool {
        switch policy.Name {
        case "always", "unless-stopped":
            return true
        case "on-failure":
            guard exitCode != 0 else { return false }
            let maxRetries = policy.MaximumRetryCount ?? 0
            return maxRetries <= 0 || attempt <= maxRetries
        default:
            return false
        }
    }

    /// Docker-style exponential backoff between restart attempts (100ms doubling, capped at 1 minute).
    static func backoffDelayNanoseconds(attempt: Int) -> UInt64 {
        let baseMillis: UInt64 = 100
        let capMillis: UInt64 = 60_000
        let shift = min(max(attempt - 1, 0), 20)
        let millis = min(capMillis, baseMillis << shift)
        return millis * 1_000_000
    }
}
