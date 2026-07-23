struct GuestProcessTimedOut: Error {}

enum GuestProcess {
    static let defaultTimeoutNs: UInt64 = 10 * 1_000_000_000

    /// `wait` is a guest XPC call that ignores cancellation, and a task group
    /// awaits every child before returning — so `terminate` must run *inside*
    /// the group to make the pending `wait` return. Killing after the group
    /// would deadlock: teardown blocks on `wait` until the guest exits anyway.
    /// Parent cancellation reaches teardown the same way (the sleep throws
    /// `CancellationError` before the deadline), so it terminates too.
    static func waitBounded(
        timeoutNs: UInt64 = defaultTimeoutNs,
        wait: @escaping @Sendable () async throws -> Int32,
        terminate: @escaping @Sendable () async -> Void
    ) async throws -> Int32 {
        enum Outcome { case exited(Int32), timedOut }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { .exited(try await wait()) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                return .timedOut
            }
            defer { group.cancelAll() }
            do {
                switch try await group.next() ?? .timedOut {
                case .exited(let code): return code
                case .timedOut:
                    await terminate()
                    throw GuestProcessTimedOut()
                }
            } catch is CancellationError {
                await terminate()
                throw CancellationError()
            }
        }
    }
}
