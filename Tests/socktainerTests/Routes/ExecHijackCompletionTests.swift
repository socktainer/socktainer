import Foundation
import Testing

@testable import socktainer

/// End-of-session sequencing of a hijacked exec start: the connection may only be
/// closed after every output pipe hit EOF, the exit code was recorded, and a flush
/// barrier completed. Closing earlier truncates the output (close fails pending
/// writes) or lets the client's GET /exec/{id}/json read no exit code.
@Suite("ExecHijackCompletion — drain, exit code, flush, close")
struct ExecHijackCompletionTests {

    private actor EventLog {
        private(set) var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    /// A one-shot gate the test opens to let a step finish.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        var isOpenNow: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isOpen
        }

        func open() {
            lock.lock()
            isOpen = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    /// Simulates an XPC `process.wait()` that never answers and ignores task
    /// cancellation. The continuation is parked forever on purpose.
    private final class StalledWait: @unchecked Sendable {
        private let lock = NSLock()
        private var parked: [CheckedContinuation<Int32?, Never>] = []

        func wait() async -> Int32? {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                lock.lock()
                parked.append(continuation)
                lock.unlock()
            }
        }
    }

    private static func run(
        log: EventLog,
        waitForExit: @escaping @Sendable () async -> Int32?,
        outputEnd: @escaping @Sendable () async -> ExecHijackCompletion.OutputEnd,
        timeout: UInt64 = 5_000_000_000
    ) async {
        await ExecHijackCompletion.run(
            waitForExit: waitForExit,
            awaitOutputEnd: {
                let end = await outputEnd()
                await log.append("outputs:\(end)")
                return end
            },
            recordExit: { code in await log.append("record:\(code.map(String.init) ?? "nil")") },
            recordStall: { await log.append("stall") },
            flush: { await log.append("flush") },
            close: { await log.append("close") },
            exitStallTimeoutNanoseconds: timeout
        )
    }

    @Test("Closes only after the outputs drained and the flush barrier ran, even when the process exited first")
    func closeWaitsForDrainAndFlush() async throws {
        let log = EventLog()
        let drained = Gate()

        let session = Task {
            await Self.run(
                log: log,
                waitForExit: { 0 },  // process already exited
                outputEnd: {
                    await drained.wait()
                    return .drained
                })
        }

        // The process exit is known, but output is still being copied: nothing may close yet.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await log.events.isEmpty)

        drained.open()
        await session.value

        #expect(await log.events == ["outputs:drained", "record:0", "flush", "close"])
    }

    @Test("Records the exit code before closing when wait() reports after output EOF")
    func exitCodeRecordedBeforeClose() async {
        let log = EventLog()

        await Self.run(
            log: log,
            waitForExit: {
                try? await Task.sleep(nanoseconds: 150_000_000)
                return 42
            },
            outputEnd: { .drained })

        #expect(await log.events == ["outputs:drained", "record:42", "flush", "close"])
    }

    /// Polls `condition` every 50 ms for up to `limit` nanoseconds.
    private static func eventually(
        within limit: UInt64 = 3_000_000_000,
        _ condition: @Sendable () async -> Bool
    ) async throws -> Bool {
        var waited: UInt64 = 0
        while !(await condition()) {
            guard waited < limit else { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 50_000_000
        }
        return true
    }

    @Test("A stalled wait() closes at the provisional sentinel within the bound, with no exit recorded")
    func stalledWaitIsBounded() async throws {
        let log = EventLog()
        let stalled = StalledWait()
        let finished = Gate()

        // Run the sequence unstructured so a regression (closing on a raw, unbounded
        // wait) fails this test instead of hanging the test run.
        Task {
            await Self.run(
                log: log,
                waitForExit: { await stalled.wait() },
                outputEnd: { .drained },
                timeout: 200_000_000)
            finished.open()
        }

        #expect(
            try await Self.eventually { finished.isOpenNow },
            "close sequence did not finish within 3 s of a stalled wait()")
        // The exit was never observed: only the sentinel, no recordExit (no registry
        // removal, no exec_die) while wait() is still pending.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await log.events == ["outputs:drained", "stall", "flush", "close"])
    }

    @Test("wait() answering after the bound replaces the sentinel with the real exit code")
    func lateExitReplacesSentinel() async throws {
        let log = EventLog()
        let exitReported = Gate()
        let finished = Gate()

        Task {
            await Self.run(
                log: log,
                waitForExit: {
                    await exitReported.wait()
                    return 5
                },
                outputEnd: { .drained },
                timeout: 100_000_000)
            finished.open()
        }

        // The bound expires: the connection closes on the sentinel.
        #expect(try await Self.eventually { finished.isOpenNow })
        #expect(await log.events == ["outputs:drained", "stall", "flush", "close"])

        // wait() reports late: the real code is recorded after the close, and last.
        exitReported.open()
        #expect(try await Self.eventually { await log.events.count == 5 })
        #expect(await log.events == ["outputs:drained", "stall", "flush", "close", "record:5"])
    }

    @Test("The bound starts at output EOF, so a long-running exec keeps its real exit code")
    func boundStartsAtOutputEOF() async {
        let log = EventLog()

        let exited = Gate()
        let waitReturned = Gate()

        // The process runs for 3x the bound; it exits as its output hits EOF, like a real
        // exec. A bound counted from process start would expire before the exit is seen.
        await Self.run(
            log: log,
            waitForExit: {
                await exited.wait()
                waitReturned.open()
                return 7
            },
            outputEnd: {
                try? await Task.sleep(nanoseconds: 300_000_000)
                exited.open()
                await waitReturned.wait()
                return .drained
            },
            timeout: 100_000_000)

        #expect(await log.events == ["outputs:drained", "record:7", "flush", "close"])
    }

    @Test("Client gone before EOF: close first, then record the real exit code without a bound")
    func clientGoneWaitsForRealExit() async {
        let log = EventLog()

        await Self.run(
            log: log,
            waitForExit: {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return 3
            },
            outputEnd: { .clientGone },
            timeout: 50_000_000)

        #expect(await log.events == ["outputs:clientGone", "close", "record:3"])
    }

    @Test("No attached output: the process exit is the end signal")
    func noOutputsWaitsForExit() async {
        let log = EventLog()

        await Self.run(
            log: log,
            waitForExit: {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return 5
            },
            outputEnd: { .noOutputs },
            timeout: 50_000_000)

        #expect(await log.events == ["outputs:noOutputs", "record:5", "flush", "close"])
    }

    @Test("A failed wait() records the sentinel (no observed exit)")
    func failedWaitRecordsSentinel() async {
        let log = EventLog()

        await Self.run(log: log, waitForExit: { nil }, outputEnd: { .drained })

        #expect(await log.events == ["outputs:drained", "record:nil", "flush", "close"])
    }
}

@Suite("ExitLatch")
struct ExitLatchTests {

    @Test("Returns a value resolved before the wait")
    func resolvedBeforeWait() async {
        let latch = ExitLatch()
        latch.resolve(9)
        #expect(await latch.value(timeoutNanoseconds: 1_000_000) == .resolved(9))
    }

    @Test("Times out and ignores a later resolution")
    func timeoutWins() async throws {
        let latch = ExitLatch()
        #expect(await latch.value(timeoutNanoseconds: 50_000_000) == .timedOut)
        latch.resolve(1)
        #expect(await latch.value(timeoutNanoseconds: nil) == .timedOut)
    }

    @Test("A failed wait is reported as resolved(nil), not as a timeout")
    func failedWaitIsNotTimeout() async {
        let latch = ExitLatch()
        latch.resolve(nil)
        #expect(await latch.value(timeoutNanoseconds: 50_000_000) == .resolved(nil))
    }

    @Test("Waits without a bound when no timeout is given")
    func unboundedWait() async {
        let latch = ExitLatch()
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            latch.resolve(4)
        }
        #expect(await latch.value(timeoutNanoseconds: nil) == .resolved(4))
    }
}

@Suite("ExecHijackCompletion — output end aggregation")
struct ExecHijackOutputEndTests {

    @Test("No readers: no output attached")
    func noReaders() {
        #expect(ExecHijackCompletion.outputEnd(readersReachedEOF: []) == .noOutputs)
    }

    @Test("Drained only when every reader reached EOF", arguments: [[true], [true, true]])
    func allEOF(results: [Bool]) {
        #expect(ExecHijackCompletion.outputEnd(readersReachedEOF: results) == .drained)
    }

    @Test(
        "Any reader that stopped early means the client went away, whatever the order",
        arguments: [[false], [false, true], [true, false], [false, false]])
    func anyEarlyStop(results: [Bool]) {
        #expect(ExecHijackCompletion.outputEnd(readersReachedEOF: results) == .clientGone)
    }
}
