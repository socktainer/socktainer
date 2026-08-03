import Foundation
import Testing

@testable import socktainer

/// `ExecRoute.waitForExitOutcome` races a process's exit against a bounded
/// timeout. It backs the cleanup on every exec-start path (detached,
/// chunked-stream, and hijacked/TCP-upgrade) — in particular, the hijacked
/// path's channel-close call is unreachable until this function returns.
///
/// Before the fix for issue #8, the hijacked path awaited `process.wait()`
/// directly with no timeout at all. If Apple Container's XPC never
/// acknowledged the exec process's exit (a stall the codebase already
/// accounts for on the other two paths), `process.wait()` would hang
/// forever and the hijacked connection's `channel.close()` would never run
/// — the exact "never closes the hijacked connection after the process
/// exits" symptom from the bug report. These tests exercise that fallback
/// directly, without needing a real Apple Container VM.
@Suite("ExecRoute.waitForExitOutcome")
struct ExecWaitOutcomeTests {

    @Test("an exit observed before the timeout is reported as observed(code)")
    func observedExitBeforeTimeout() async {
        let outcome = await ExecRoute.waitForExitOutcome(timeoutNanoseconds: 5_000_000_000) {
            42
        }

        #expect(outcome == .observed(42))
    }

    @Test("a wait() that throws is treated as unresolved, not a crash")
    func throwingWaitIsUnresolved() async {
        struct BoomError: Error {}

        let outcome = await ExecRoute.waitForExitOutcome(timeoutNanoseconds: 5_000_000_000) {
            throw BoomError()
        }

        #expect(outcome == .unresolved)
    }

    @Test("a wait() that never resolves still returns unresolved within the timeout bound")
    func stalledWaitFallsBackWithinTimeout() async throws {
        // Regression test for issue #8: a wait() that never completes (the
        // XPC-stall scenario) must not hang the caller forever. Without the
        // fix's timeout race, this call would never return and the test
        // itself would hang — mirroring how a stalled process.wait() left
        // the hijacked channel open forever.
        //
        // Simulated here with a continuation that only resumes via a real-time
        // callback, never observing Task cancellation — a genuinely
        // non-cooperative stall. (A `Task.sleep`-based stand-in would throw
        // `CancellationError` the instant it's cancelled, masking the bug
        // this test guards against: the caller must not depend on the loser
        // task ever finishing, cooperatively or otherwise.)
        let timeoutNanoseconds: UInt64 = 100_000_000  // 100ms
        let start = DispatchTime.now().uptimeNanoseconds

        let outcome = await ExecRoute.waitForExitOutcome(timeoutNanoseconds: timeoutNanoseconds) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                    continuation.resume()
                }
            }
            return 0
        }

        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start

        #expect(outcome == .unresolved)
        // Generous upper bound (2s) well above the 100ms timeout, but far
        // below the 60s stall — proves the call returned promptly on the
        // timeout path rather than eventually finishing the stalled wait.
        #expect(elapsedNanoseconds < 2_000_000_000)
    }

    @Test("a fast exit still wins even with a short timeout")
    func fastExitWinsOverShortTimeout() async {
        let outcome = await ExecRoute.waitForExitOutcome(timeoutNanoseconds: 50_000_000) {
            7
        }

        #expect(outcome == .observed(7))
    }
}
