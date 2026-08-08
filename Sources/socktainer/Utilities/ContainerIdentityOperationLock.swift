import Foundation

/// Serializes Docker-visible identity mutations and their dependent side effects.
///
/// The durable metadata actor makes each name change atomic, but route work after
/// that commit (DNS and event publication) is asynchronous. Without a wider
/// boundary, two concurrent renames can commit in order and publish their side
/// effects in reverse order. This keyed FIFO lock preserves Docker's observable
/// mutation order without serializing unrelated containers.
actor ContainerIdentityOperationLock {
    static let shared = ContainerIdentityOperationLock()

    private struct State {
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var states: [String: State] = [:]

    func withLock<T: Sendable>(
        containerID: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(containerID: containerID)
        do {
            let result = try await operation()
            release(containerID: containerID)
            return result
        } catch {
            release(containerID: containerID)
            throw error
        }
    }

    private func acquire(containerID: String) async {
        if states[containerID]?.held != true {
            states[containerID] = State(held: true)
            return
        }
        await withCheckedContinuation { continuation in
            var state = states[containerID] ?? State(held: true)
            state.waiters.append(continuation)
            states[containerID] = state
        }
    }

    private func release(containerID: String) {
        guard var state = states[containerID] else { return }
        if state.waiters.isEmpty {
            states.removeValue(forKey: containerID)
        } else {
            let next = state.waiters.removeFirst()
            states[containerID] = state
            next.resume()
        }
    }
}
