import Foundation
import Testing

@testable import socktainer

@Suite("ContainerExitCodeStore — waitForCode")
struct ContainerExitCodeStoreTests {

    @Test("a recovered waiter cannot overwrite a later run's exit code")
    func rejectsStaleRecoveredWaiter() async {
        let store = ContainerExitCodeStore()
        let token = await store.currentGeneration(id: "reused")
        await store.remove(id: "reused")
        await store.set(id: "reused", code: 11)
        #expect(await store.set(id: "reused", code: 7, generation: token) == false)
        #expect(await store.get(id: "reused") == 11)
    }

    @Test("a recovered waiter for the current run publishes the real code")
    func acceptsCurrentRecoveredWaiter() async {
        let store = ContainerExitCodeStore()
        let token = await store.currentGeneration(id: "current")
        #expect(await store.set(id: "current", code: 23, generation: token))
        #expect(await store.get(id: "current") == 23)
    }

    @Test("waitForCode returns immediately when the code is already recorded")
    func returnsAlreadyRecorded() async throws {
        let store = ContainerExitCodeStore()
        let id = "ctr-pre-\(Int.random(in: 10000...99999))"
        await store.set(id: id, code: 7)
        let code = await store.waitForCode(id: id)
        #expect(code == 7)
    }

    @Test("waitForCode suspends until set() records the code, then returns it")
    func resumesOnSet() async throws {
        let store = ContainerExitCodeStore()
        let id = "ctr-wait-\(Int.random(in: 10000...99999))"

        // Start awaiting before the code exists — this must suspend, not return 0.
        let waiter = Task { await store.waitForCode(id: id) }

        // Give the waiter a moment to register, then record the real code.
        try await Task.sleep(nanoseconds: 100_000_000)
        await store.set(id: id, code: 42)

        let code = await waiter.value
        #expect(code == 42, "must deliver the recorded code, not a 0 fallback")
    }
}

private struct WaitError: Error {}

@Suite("ContainerExitCodeStore — resolveExitCode retry")
struct ResolveExitCodeTests {

    @Test("returns the code immediately when wait() succeeds first try")
    func succeedsFirstTry() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: 0) {
            calls += 1
            return 7
        }
        #expect(code == 7)
        #expect(calls == 1)
    }

    // A transient throw from the wait XPC round-trip must NOT be recorded as a fake exit
    // code of 0. Retrying yields the authoritative code (7).
    @Test("retries past transient throws and returns the real code")
    func retriesPastTransientThrows() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: 0) {
            calls += 1
            if calls < 3 { throw WaitError() }
            return 7
        }
        #expect(code == 7, "transient wait() failures must not collapse into exit code 0")
        #expect(calls == 3)
    }

    @Test("returns the failure sentinel (not 0) when every attempt throws")
    func sentinelOnPersistentFailure() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(maxAttempts: 4, retryDelayNs: 0) {
            calls += 1
            throw WaitError()
        }
        #expect(code == ContainerExitCodeStore.waitFailureSentinel)
        #expect(code != 0, "a failed wait must be distinguishable from a genuine exit-0")
        #expect(calls == 4)
    }

    @Test("timed waitForCode returns a code that is already recorded")
    func timedReturnsAlreadyRecorded() async {
        let store = ContainerExitCodeStore()
        await store.set(id: "timed-pre", code: 5)
        #expect(await store.waitForCode(id: "timed-pre", timeout: .seconds(3)) == 5)
    }

    @Test("timed waitForCode resumes as soon as the code is recorded, not at the timeout")
    func timedResumesOnSet() async {
        // `docker run --rm` hit this path on every run: auto-remove deleted the container
        // before the attach stream recorded the exit code, and wait() then slept in fixed
        // 100ms steps. The waiter must wake on set(), well before its timeout.
        let store = ContainerExitCodeStore()
        // The timeout is far longer than any wait the test makes, so a code that arrives means
        // set() woke the waiter. The margins are wide because CI runners can stall for seconds.
        async let code = store.waitForCode(id: "timed-late", timeout: .seconds(60))

        // Make sure the waiter is registered before recording the code; otherwise set()
        // could win the race and the test would only cover the already-recorded path.
        // Bounded, so a registration failure fails the test instead of hanging it.
        let deadline = ContinuousClock.now + .seconds(20)
        var registered = false
        while ContinuousClock.now < deadline {
            if await store.pendingTimedWaiters(id: "timed-late") == 1 {
                registered = true
                break
            }
            await Task.yield()
        }
        #expect(registered, "the timed waiter never registered")

        let setAt = ContinuousClock.now
        await store.set(id: "timed-late", code: 9)
        #expect(await code == 9)
        #expect(ContinuousClock.now - setAt < .seconds(20), "the waiter must wake on set(), not at its timeout")
        #expect(await store.pendingTimedWaiters(id: "timed-late") == 0)
    }

    @Test("timed waitForCode returns nil after the timeout and drops the waiter")
    func timedExpires() async {
        let store = ContainerExitCodeStore()
        #expect(await store.waitForCode(id: "timed-never", timeout: .milliseconds(30)) == nil)
        #expect(await store.pendingTimedWaiters(id: "timed-never") == 0)
        // A code recorded after expiry is still stored for later readers.
        await store.set(id: "timed-never", code: 4)
        #expect(await store.get(id: "timed-never") == 4)
    }
}
