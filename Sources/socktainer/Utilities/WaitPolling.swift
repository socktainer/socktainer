import Foundation

/// Polling with exponential backoff for `POST /containers/{id}/wait`.
///
/// Apple Container offers no notification when a container is auto-removed, so
/// `wait` has to poll. A fixed interval makes every short-lived `docker run --rm`
/// pay up to a full interval after the container is already gone. Starting small
/// and doubling up to a cap keeps the common case fast while long waits settle
/// at the same rate as before.
enum WaitPolling {
    /// First delay before re-checking the condition.
    static let initialDelay: Duration = .milliseconds(10)
    /// Cap for the exit-code loop; matches the previous fixed interval.
    static let exitDelayCap: Duration = .milliseconds(100)
    /// Cap for the removal loop; matches the previous fixed interval.
    static let removalDelayCap: Duration = .milliseconds(200)

    /// The delay to use after `delay`: doubled, but never above `cap`.
    static func nextDelay(after delay: Duration, cap: Duration) -> Duration {
        min(delay * 2, cap)
    }

    /// Calls `isDone` until it returns true, sleeping with exponential backoff between checks.
    /// Returns immediately, without sleeping, when the condition already holds.
    static func poll(
        initial: Duration = initialDelay,
        cap: Duration,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        until isDone: () async throws -> Bool
    ) async throws {
        var delay = min(initial, cap)
        while try await !isDone() {
            try await sleep(delay)
            delay = nextDelay(after: delay, cap: cap)
        }
    }
}
