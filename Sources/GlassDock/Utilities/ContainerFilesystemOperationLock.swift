import Foundation

/// Serializes operations that either materialize/mutate a container's EXT4 image
/// or hand that image to a running VM. The Apple runtime creates the writable
/// bundle lazily at bootstrap, so archive and bootstrap operations must share the
/// same per-container exclusion boundary.
actor ContainerFilesystemOperationLock {
    static let shared = ContainerFilesystemOperationLock()

    private struct State {
        var held = false
        var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    }

    private var states: [String: State] = [:]

    func withLock<T: Sendable>(
        containerID: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(containerID: containerID)
        do {
            let result = try await operation()
            release(containerID: containerID)
            return result
        } catch {
            release(containerID: containerID)
            throw error
        }
    }

    private func acquire(containerID: String) async throws {
        try Task.checkCancellation()
        if states[containerID]?.held != true {
            states[containerID] = State(held: true)
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    var state = states[containerID] ?? State(held: true)
                    state.waiters.append((waiterID, continuation))
                    states[containerID] = state
                }
            }
            if Task.isCancelled {
                release(containerID: containerID)
                throw CancellationError()
            }
        } onCancel: {
            Task { await self.cancel(containerID: containerID, waiterID: waiterID) }
        }
    }

    private func cancel(containerID: String, waiterID: UUID) {
        guard var state = states[containerID],
            let index = state.waiters.firstIndex(where: { $0.0 == waiterID })
        else { return }
        state.waiters.remove(at: index).1.resume(throwing: CancellationError())
        states[containerID] = state
    }

    private func release(containerID: String) {
        guard var state = states[containerID] else { return }
        if state.waiters.isEmpty {
            states.removeValue(forKey: containerID)
        } else {
            let waiter = state.waiters.removeFirst()
            states[containerID] = state
            waiter.1.resume()
        }
    }
}
