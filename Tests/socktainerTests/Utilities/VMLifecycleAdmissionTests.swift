import Foundation
import Testing

@testable import socktainer

private struct SyntheticError: Error {}

@Suite("VMLifecycleAdmission")
struct VMLifecycleAdmissionTests {

    @Test("Runs immediately while slots are available")
    func runsImmediatelyUnderLimit() async throws {
        let admission = VMLifecycleAdmission(limit: 2)
        let result = try await admission.withSlot { 42 }
        #expect(result == 42)
    }

    @Test("A call beyond the limit blocks until a slot is released")
    func blocksBeyondLimit() async throws {
        let admission = VMLifecycleAdmission(limit: 1)

        // Occupy the only slot first, confirmed via a signal, before the waiter can race for it.
        let holderAcquired = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await admission.withSlot {
                holderAcquired.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var acquiredIterator = holderAcquired.stream.makeAsyncIterator()
        _ = await acquiredIterator.next()

        let releasedAt = Date()
        let waiterTask = Task { () -> Date in
            try await admission.withSlot { Date() }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        try await holder.value

        let acquiredAt = try await waiterTask.value
        #expect(acquiredAt.timeIntervalSince(releasedAt) >= 0.05)
    }

    @Test("Releases the slot even when body throws")
    func releasesOnThrow() async {
        let admission = VMLifecycleAdmission(limit: 1)

        await #expect(throws: SyntheticError.self) {
            try await admission.withSlot { throw SyntheticError() }
        }

        // If the slot weren't released on throw, this would hang.
        let result = try? await admission.withSlot { "recovered" }
        #expect(result == "recovered")
    }

    @Test("Released slots are handed to waiters in FIFO order")
    func fifoOrdering() async throws {
        actor OrderLog {
            private(set) var order: [Int] = []
            func record(_ value: Int) { order.append(value) }
        }

        let admission = VMLifecycleAdmission(limit: 1)
        let log = OrderLog()
        let gate = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await admission.withSlot {
                for await _ in gate.stream { break }
            }
        }
        // Give the holder time to actually acquire before queuing waiters.
        try? await Task.sleep(nanoseconds: 20_000_000)

        let task1 = Task {
            try await admission.withSlot { await log.record(1) }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let task2 = Task {
            try await admission.withSlot { await log.record(2) }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        gate.continuation.yield(())
        gate.continuation.finish()
        _ = try await holder.value
        _ = try await task1.value
        _ = try await task2.value

        #expect(await log.order == [1, 2])
    }

    @Test("defaultLimit is at least 2")
    func defaultLimitHasFloor() {
        #expect(VMLifecycleAdmission.defaultLimit >= 2)
    }
}
