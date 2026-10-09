import Foundation
import Testing

@testable import socktainer

@Suite("Startup housekeeping deadline")
struct StartupHousekeepingTests {

    @Test("work that finishes in time returns true")
    func finishesInTime() async {
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(5)) {
            // completes immediately
        }
        #expect(finished == true)
    }

    @Test("work that outlives the deadline is abandoned and returns false")
    func abandonedAtDeadline() async {
        let finished = await StartupHousekeeping.runBounded(timeout: .milliseconds(50)) {
            // Simulates an XPC await that never resolves and ignores
            // cancellation — sleep is cancellable, but nothing cancels the
            // abandoned task, so it stands in for a stuck continuation.
            try? await Task.sleep(for: .seconds(600))
        }
        #expect(finished == false)
    }

    @Test("work finishing after the deadline does not double-resume")
    func lateFinishIsHarmless() async throws {
        let finished = await StartupHousekeeping.runBounded(timeout: .milliseconds(20)) {
            try? await Task.sleep(for: .milliseconds(60))
        }
        #expect(finished == false)
        // Give the late worker time to complete its claim() after the timeout
        // already resumed — a double-resume would crash the process here.
        try await Task.sleep(for: .milliseconds(120))
    }

    @Test("slow-but-in-time work still returns true")
    func slowWorkWithinDeadline() async {
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(5)) {
            try? await Task.sleep(for: .milliseconds(30))
        }
        #expect(finished == true)
    }

    @Test("work that finishes first cancels the deadline timer instead of leaving it asleep")
    func finishedWorkCancelsTimer() async {
        let timer = ParkedSleep()
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(600), sleep: timer.sleep) {
            // completes immediately
        }
        #expect(finished == true)

        // The timer parks until cancelled; nothing else wakes it. The watchdog only
        // bounds the test if the cancel never comes.
        let cancelled = await StartupHousekeeping.runBounded(timeout: .seconds(30)) {
            await timer.waitUntilCancelled()
        }
        #expect(cancelled, "the deadline timer was still sleeping after the work finished")
    }

    @Test("work that outlives the deadline still times out with an injected sleep")
    func injectedSleepDrivesDeadline() async {
        let work = ParkedSleep()
        defer { work.cancelAll() }
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(600), sleep: { _ in }) {
            try? await work.sleep(.seconds(600))
        }
        #expect(finished == false)
    }
}

/// A sleep that never ends on its own: it parks until its task is cancelled, then
/// throws `CancellationError` like `Task.sleep`. Records each cancellation.
private final class ParkedSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledIds: Set<UUID> = []
    private var cancellations = 0
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if closed || cancelledIds.contains(id) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                parked[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            wake(id)
        }
        throw CancellationError()
    }

    func waitUntilCancelled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if cancellations > 0 {
                lock.unlock()
                continuation.resume()
                return
            }
            cancelWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Wakes every parked sleep, and any later one at once, so abandoned tasks can end.
    func cancelAll() {
        lock.lock()
        closed = true
        let ids = Array(parked.keys)
        lock.unlock()
        for id in ids { wake(id) }
    }

    private func wake(_ id: UUID) {
        lock.lock()
        cancelledIds.insert(id)
        cancellations += 1
        let continuation = parked.removeValue(forKey: id)
        let waiters = cancelWaiters
        cancelWaiters = []
        lock.unlock()
        continuation?.resume()
        for waiter in waiters { waiter.resume() }
    }
}
