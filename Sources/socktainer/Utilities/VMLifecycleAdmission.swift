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
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    /// Runs `body` while holding one admission slot, queuing (FIFO) if none are free.
    /// A `restart` (stop, then start) should wrap both under a single `withSlot` call rather
    /// than acquiring twice, so the container isn't left stopped while other queued work runs.
    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        // A task cancelled before ever reaching acquire() (e.g. the holder released and a
        // slot became free before this task's body was even scheduled) must not silently
        // acquire via the fast path below, which has no cancellation check of its own.
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // onCancel fires immediately for an already-cancelled task and only spawns a
                // Task to reach this actor, racing against this closure's own append — if that
                // Task wins, cancelWaiter finds nothing and the append below would otherwise
                // orphan a waiter that release() later resumes normally instead of throwing.
                // Checking cancellation here, synchronously before appending, closes that gap.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
            // A second race remains even after the check above: release() and cancelWaiter's
            // spawned Task both independently compete to touch this waiter, and release() can
            // win, resuming us normally before cancelWaiter ever runs (it then no-ops, finding
            // nothing left to remove). Re-checking here catches that case — hand the slot we
            // were just granted back to the pool instead of silently keeping it.
            if Task.isCancelled {
                release()
                throw CancellationError()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    // A cancelled caller that already left `waiters` (raced with `release()`) is a no-op here —
    // whichever of the two touches it first wins, since both run serialized on this actor.
    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            available += 1
        }
    }
}
