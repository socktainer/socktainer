import Testing

@testable import socktainer

@Suite("GuestProcess.waitBounded")
struct GuestProcessTests {

    private struct WaitFailed: Error {}
    private static let never: UInt64 = 60 * 1_000_000_000

    private enum Event: Equatable { case terminated, waitReturned }

    private actor EventLog {
        private(set) var events: [Event] = []
        func record(_ event: Event) { events.append(event) }
    }

    /// A `wait` that ignores cancellation and returns only once opened, modelling
    /// the guest XPC wait that `terminate` must unblock.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            guard !isOpen else { return }
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("on timeout it terminates the guest first, which is what lets the non-cancellable wait return")
    func terminationUnblocksNonCancellableWait() async throws {
        let gate = Gate()
        let log = EventLog()
        let fuse = Task {
            guard (try? await Task.sleep(nanoseconds: 2_000_000_000)) != nil else { return }
            await gate.open()
        }
        defer { fuse.cancel() }

        await #expect(throws: GuestProcessTimedOut.self) {
            try await GuestProcess.waitBounded(
                timeoutNs: 20_000_000,
                wait: {
                    await gate.wait()
                    await log.record(.waitReturned)
                    return 0
                },
                terminate: {
                    await log.record(.terminated)
                    await gate.open()
                }
            )
        }
        #expect(await log.events == [.terminated, .waitReturned])
    }

    @Test("parent cancellation terminates the guest so teardown can't deadlock on the non-cancellable wait")
    func cancellationTerminatesAndUnblocksWait() async {
        let gate = Gate()
        let log = EventLog()
        let fuse = Task {
            guard (try? await Task.sleep(nanoseconds: 2_000_000_000)) != nil else { return }
            await gate.open()
        }
        defer { fuse.cancel() }

        let task = Task {
            try await GuestProcess.waitBounded(
                timeoutNs: Self.never,
                wait: {
                    await gate.wait()
                    await log.record(.waitReturned)
                    return 0
                },
                terminate: {
                    await log.record(.terminated)
                    await gate.open()
                }
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let thrown: Error?
        switch await task.result {
        case .success: thrown = nil
        case .failure(let error): thrown = error
        }
        #expect(thrown is CancellationError)
        #expect(await log.events == [.terminated, .waitReturned])
    }

    @Test("a wait that returns before the deadline yields its exit code and never terminates")
    func returnsExitCodeWithoutTerminating() async throws {
        try await confirmation("terminate is not called", expectedCount: 0) { terminated in
            let code = try await GuestProcess.waitBounded(
                timeoutNs: Self.never,
                wait: { 42 },
                terminate: { terminated() }
            )
            #expect(code == 42)
        }
    }

    @Test("a wait that throws propagates its own error without terminating")
    func propagatesWaitErrorWithoutTerminating() async {
        await confirmation("terminate is not called", expectedCount: 0) { terminated in
            _ = await #expect(throws: WaitFailed.self) {
                try await GuestProcess.waitBounded(
                    timeoutNs: Self.never,
                    wait: { throw WaitFailed() },
                    terminate: { terminated() }
                )
            }
        }
    }
}
