import Foundation

/// End-of-session sequencing for a hijacked (`Upgrade: tcp`) `POST /exec/{id}/start`.
///
/// The hijacked connection carries no framing, so closing it is the only end-of-output
/// signal the client gets, and the client reads the exit code with `GET /exec/{id}/json`
/// right after it sees EOF. Closing therefore has to wait for two things:
///
/// 1. every output pipe reaching EOF (Apple's runtime closes the host write ends after
///    its own wait on the process returns), followed by a flush barrier on the channel,
///    so no queued output is dropped, and
/// 2. the exit code being recorded.
///
/// Apple Container's XPC sometimes never answers `process.wait()`, and the reply is awaited
/// in a continuation with no cancellation handler (ContainerXPC `XPCClient.send`), so
/// cancelling a task-group race does not end it. The exit code is awaited through
/// ``ExitLatch`` instead, a first-wins latch that a timer can resolve on its own. The
/// bound only starts once the output is drained: a long-running exec (`exec -it`, a long
/// CI step) is never cut short.
enum ExecHijackCompletion {
    /// Time allowed for `process.wait()` to report after all output pipes hit EOF before
    /// the connection is closed with the exit code recorded as unknown (-1, matching the
    /// HTTP streaming fallback). The sentinel is provisional: the wait keeps running, and
    /// whatever it reports later replaces it.
    static let exitCodeStallTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// How the output side of the session ended.
    enum OutputEnd: Sendable, Equatable {
        /// Every attached output pipe reached EOF: the process closed its output.
        case drained
        /// A reader stopped before EOF because the client connection went away.
        case clientGone
        /// No output stream is attached, so there is no EOF to wait for.
        case noOutputs
    }

    /// Maps the output readers' results (`true` = that pipe reached EOF) to how the
    /// output side ended: `.drained` only when every reader reached EOF.
    static func outputEnd(readersReachedEOF results: [Bool]) -> OutputEnd {
        guard !results.isEmpty else { return .noOutputs }
        return results.allSatisfy { $0 } ? .drained : .clientGone
    }

    /// Runs the end-of-session sequence.
    ///
    /// - `waitForExit` starts immediately (an unstructured task) and returns the observed
    ///   exit code, or `nil` if waiting failed.
    /// - `.drained`: the exit code is awaited for at most `exitStallTimeoutNanoseconds`,
    ///   passed to `recordExit`, then `flush` and `close` run in that order. If the bound
    ///   expires first, `recordStall` runs instead (the exit has not been observed), then
    ///   `flush` and `close`; a detached task keeps waiting and calls `recordExit` with
    ///   whatever the wait finally reports, so a late exit code replaces the sentinel.
    ///   `run` does not wait for that task: a wait that never answers cannot pin it.
    /// - `.noOutputs`: the process exit is the only end signal, so it is awaited without
    ///   a bound (as before), then record, flush, close.
    /// - `.clientGone`: the connection is already gone, so `close` runs first; the exit
    ///   code is then awaited without a bound so the real code is still recorded.
    static func run(
        waitForExit: @escaping @Sendable () async -> Int32?,
        awaitOutputEnd: @Sendable () async -> OutputEnd,
        recordExit: @escaping @Sendable (Int32?) async -> Void,
        recordStall: @Sendable () async -> Void,
        flush: @Sendable () async -> Void,
        close: @Sendable () async -> Void,
        exitStallTimeoutNanoseconds: UInt64 = exitCodeStallTimeoutNanoseconds
    ) async {
        let latch = ExitLatch()
        let waiter = Task.detached { () -> Int32? in
            let code = await waitForExit()
            latch.resolve(code)
            return code
        }

        switch await awaitOutputEnd() {
        case .drained:
            switch await latch.value(timeoutNanoseconds: exitStallTimeoutNanoseconds) {
            case .resolved(let code):
                await recordExit(code)
                await flush()
                await close()
            case .timedOut:
                await recordStall()
                await flush()
                await close()
                Task.detached { await recordExit(await waiter.value) }
            }
        case .noOutputs:
            await recordExit(await waiter.value)
            await flush()
            await close()
        case .clientGone:
            await close()
            await recordExit(await waiter.value)
        }
    }
}

/// One-shot holder for an exec's exit code. The first of `resolve` or the waiter's
/// timeout wins; later resolutions are ignored. Neither path depends on the other
/// honoring cancellation, so a stalled `process.wait()` cannot hold up a bounded waiter.
final class ExitLatch: @unchecked Sendable {
    /// What the waiter gets: the wait's outcome (`nil` = the wait failed) or the timeout.
    enum Outcome: Sendable, Equatable {
        case resolved(Int32?)
        case timedOut
    }

    private enum State {
        case pending(CheckedContinuation<Outcome, Never>?)
        case done(Outcome)
    }

    private let lock = NSLock()
    private var state: State = .pending(nil)
    private var timer: Task<Void, Never>?

    init() {}

    /// Records the outcome of waiting for the process (`nil` = the wait failed).
    func resolve(_ code: Int32?) {
        finish(.resolved(code))
    }

    /// Returns the resolved exit code, or `.timedOut` if it is not resolved within the
    /// timeout (`nil` timeout = wait indefinitely). Supports a single waiter.
    func value(timeoutNanoseconds: UInt64?) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            guard register(continuation) else { return }
            if let timeoutNanoseconds {
                let timer = Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    self?.finish(.timedOut)
                }
                setTimer(timer)
            }
        }
    }

    /// Stores the waiter, or resumes it immediately when already resolved.
    /// Returns `false` when the continuation was resumed immediately.
    private func register(_ continuation: CheckedContinuation<Outcome, Never>) -> Bool {
        lock.lock()
        switch state {
        case .done(let outcome):
            lock.unlock()
            continuation.resume(returning: outcome)
            return false
        case .pending:
            state = .pending(continuation)
            lock.unlock()
            return true
        }
    }

    private func setTimer(_ newTimer: Task<Void, Never>) {
        lock.lock()
        if case .done = state {
            lock.unlock()
            newTimer.cancel()
            return
        }
        timer = newTimer
        lock.unlock()
    }

    private func finish(_ outcome: Outcome) {
        lock.lock()
        guard case .pending(let waiter) = state else {
            lock.unlock()
            return
        }
        state = .done(outcome)
        let pendingTimer = timer
        timer = nil
        lock.unlock()
        pendingTimer?.cancel()
        waiter?.resume(returning: outcome)
    }
}
