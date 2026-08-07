/// Serializes Docker-visible image mutations and gives readers a stable epoch.
///
/// Apple Container's image store replaces only an exact string key. Docker, by
/// contrast, has one canonical tag owner. A load followed by the canonical-tag
/// reconciliation therefore spans several Apple operations. Readers must not
/// publish or consume the intermediate state, and concurrent mutations must be
/// ordered by completion just like moby's reference-store mutex.
final class ImageMutationCoordinator: Sendable {
    private let lock = ImageMutationLock()
    private let epoch = ImageMutationEpoch()

    func performMutation<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await lock.withLock {
            await self.epoch.begin()
            do {
                // A writer can be cancelled in the narrow interval between lock
                // admission and epoch.begin(). Never run a queued mutation body
                // after its client has disconnected.
                try Task.checkCancellation()
                let result = try await operation()
                await self.epoch.end()
                return result
            } catch {
                await self.epoch.end()
                throw error
            }
        }
    }

    /// Retries a read if it overlapped a coordinated mutation. The operation
    /// may perform arbitrary async catalog hydration; its result becomes visible
    /// only when the epoch is still the one in which the read began.
    func stableRead<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        while true {
            try Task.checkCancellation()
            let generation = try await epoch.stableGeneration()
            do {
                let result = try await operation()
                try Task.checkCancellation()
                guard await epoch.isStable(generation) else { continue }
                return result
            } catch {
                // A catalogue refresh cancelled by invalidate() is retried when
                // its epoch moved. Cancellation of the calling request itself is
                // terminal and must not turn into another read attempt.
                try Task.checkCancellation()
                guard await epoch.isStable(generation) else { continue }
                throw error
            }
        }
    }

    /// Runs a non-idempotent read-side operation while excluding tag mutation.
    /// Push and save use a string reference in Apple's API after resolving it;
    /// retrying them like a pure read could publish the wrong root twice. Holding
    /// the same lock as writers preserves the selected tag for the operation.
    func withMutationExcluded<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await lock.withLock {
            try await operation()
        }
    }
}

/// A small FIFO async lock whose queued waiters can be removed on cancellation.
/// ContainerizationExtras.AsyncLock deliberately ignores task cancellation: a
/// cancelled waiter remains queued and later executes its closure. That is unsafe
/// for pull/load/tag because the request may already have gone away by then.
private final class ImageMutationLock: Sendable {
    private let state = ImageMutationLockState()

    func withLock<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let id = await state.reserveID()
        try await withTaskCancellationHandler {
            try await state.acquire(id: id)
        } onCancel: {
            Task { await self.state.cancel(id: id) }
        }

        do {
            // Handles cancellation after the waiter was selected but before its
            // suspended task resumed. The body is never invoked in that case.
            try Task.checkCancellation()
            let result = try await operation()
            await state.release(id: id)
            return result
        } catch {
            await state.release(id: id)
            throw error
        }
    }
}

private actor ImageMutationLockState {
    private typealias Waiter = CheckedContinuation<Void, any Error>

    private var owner: UInt64?
    private var nextID: UInt64 = 0
    private var order: [UInt64] = []
    private var nextWaiterIndex = 0
    private var waiters: [UInt64: Waiter] = [:]

    func reserveID() -> UInt64 {
        defer { nextID &+= 1 }
        return nextID
    }

    func acquire(id: UInt64) async throws {
        if owner == nil {
            owner = id
            return
        }

        let _: Void = try await withCheckedThrowingContinuation {
            (continuation: Waiter) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            order.append(id)
            waiters[id] = continuation
        }
    }

    func cancel(id: UInt64) {
        // Once admitted, only the owner may release the lock. Releasing here
        // would overlap a mutation whose operation is still unwinding.
        guard owner != id, let continuation = waiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    func release(id: UInt64) {
        precondition(owner == id, "image mutation lock released by a non-owner")
        while nextWaiterIndex < order.count {
            let next = order[nextWaiterIndex]
            nextWaiterIndex += 1
            guard let continuation = waiters.removeValue(forKey: next) else {
                continue
            }
            owner = next
            continuation.resume()
            return
        }
        order.removeAll(keepingCapacity: true)
        nextWaiterIndex = 0
        owner = nil
    }
}

private actor ImageMutationEpoch {
    private typealias Waiter = CheckedContinuation<Void, any Error>

    private var mutationActive = false
    private var generation: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: Waiter] = [:]

    func begin() {
        precondition(!mutationActive, "image mutation lock admitted two writers")
        mutationActive = true
    }

    func end() {
        precondition(mutationActive, "image mutation ended without a writer")
        mutationActive = false
        generation &+= 1
        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        pending.forEach { $0.resume() }
    }

    func stableGeneration() async throws -> UInt64 {
        try Task.checkCancellation()
        while mutationActive {
            let id = nextWaiterID
            nextWaiterID &+= 1
            let _: Void = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: Waiter) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard mutationActive else {
                        continuation.resume()
                        return
                    }
                    waiters[id] = continuation
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: id) }
            }
            try Task.checkCancellation()
        }
        return generation
    }

    func isStable(_ expected: UInt64) -> Bool {
        !mutationActive && generation == expected
    }

    private func cancelWaiter(id: UInt64) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
