import Foundation

/// Runs best-effort startup work under a deadline that the work itself cannot
/// extend or ignore.
///
/// Startup housekeeping, such as orphaned-network reaping, calls
/// into Apple Container over XPC, and those calls can hang forever when the
/// runtime is wedged (apple/container#1884: per-container/network operations
/// hang indefinitely while reads keep working). Task cancellation can't
/// interrupt an await stuck inside an XPC continuation, so a plain
/// timeout-and-cancel race deadlocks with it. Instead the work runs in a
/// detached task and the caller resumes on whichever finishes first — the work
/// or the deadline. On timeout the stuck task is abandoned (it holds no
/// resources the daemon needs) so startup can proceed and bind the API socket;
/// the alternative is a daemon that never comes up at all.
enum StartupHousekeeping {
    /// Runs `work`, returning `true` if it finished within `timeout` and
    /// `false` if it was abandoned at the deadline.
    static func runBounded(timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return false }
                resumed = true
                return true
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task.detached {
                await work()
                if once.claim() { continuation.resume(returning: true) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}
