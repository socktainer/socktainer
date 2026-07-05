import Foundation

/// Limits how many containers may be simultaneously transitioning their `VZVirtualMachine`
/// state (booting or tearing down) rather than how many may run in total. Apple Container's
/// Virtualization.framework has been observed to fail to service virtio-net queues promptly
/// under concurrent VM state transitions (guest kernel `NETDEV WATCHDOG` timeouts cascading
/// into DNS/connect failures and, in the worst case, a guest kernel panic) when many
/// containers boot or stop at once — e.g. `docker compose up`/`down`, `supabase start`/`stop`.
///
/// Boot and stop share ONE pool rather than separate pools: both spike the same finite
/// resource (the host's capacity to service concurrent VZ state transitions), so a boot storm
/// and a stop storm must not be allowed to run concurrently and compound each other. `kill`
/// only delivers a signal (no VZ transition) and isn't gated; the VM teardown that may follow
/// happens through the already-gated stop path.
actor VMLifecycleAdmission {
    static let shared = VMLifecycleAdmission(limit: VMLifecycleAdmission.defaultLimit)

    static var defaultLimit: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 4)
    }

    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    /// Runs `body` while holding one admission slot, queuing (FIFO) if none are free.
    /// A `restart` (stop, then start) should wrap both under a single `withSlot` call rather
    /// than acquiring twice, so the container isn't left stopped while other queued work runs.
    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
