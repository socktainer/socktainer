import Testing

@testable import GlassDock

@Suite("Guest runtime restart persistence")
struct GuestRuntimePersistenceTests {
    @Test("guest port allocation reuses the lowest released port")
    func reusesLowestReleasedPort() {
        #expect(
            GuestRuntime.lowestAvailableGuestPorts(
                count: 2,
                range: 20_000...20_003,
                excluding: [20_001, 20_003]
            ) == [20_000, 20_002]
        )
    }

    @Test("guest port allocation preserves restored live assignments")
    func preservesRestoredAssignments() {
        #expect(
            GuestRuntime.lowestAvailableGuestPorts(
                count: 1,
                range: 20_000...20_003,
                excluding: [20_000, 20_002]
            ) == [20_001]
        )
    }

    @Test("vsock publication identifiers use the available high port range")
    func publishedPortProxyRange() {
        #expect(PublishedPortProxyRange.ports.lowerBound == 20_000)
        #expect(PublishedPortProxyRange.ports.upperBound == Int(UInt16.max))
        #expect(PublishedPortProxyRange.ports.count == 45_536)
    }

    @Test("guest port allocation rejects range exhaustion without partial allocation")
    func guestPortRangeExhaustion() {
        let range = 20_000...20_031
        #expect(
            GuestRuntime.lowestAvailableGuestPorts(count: 32, range: range, excluding: [])?.count == 32
        )
        #expect(
            GuestRuntime.lowestAvailableGuestPorts(count: 33, range: range, excluding: []) == nil
        )
        #expect(
            GuestRuntime.lowestAvailableGuestPorts(
                count: 1, range: range, excluding: Set(range)
            ) == nil
        )
        #expect(
            GuestRuntime.lowestAvailableGuestPorts(count: 0, range: range, excluding: Set(range)) == []
        )
    }

    @Test("event monitoring reconnects after the first stream ends")
    func eventMonitorReconnects() async throws {
        let first = AsyncStream<GuestFrame>.makeStream()
        let second = AsyncStream<GuestFrame>.makeStream()
        let connector = FakeGuestRuntimeEventConnector(streams: [first.stream, second.stream])
        let recorder = GuestRuntimeEventRecorder()
        let monitor = GuestRuntimeEventMonitor(connector: connector) { event in
            await recorder.record(event.method ?? "")
        }
        try await monitor.start()

        first.continuation.yield(Self.event("first"))
        await recorder.waitForCount(1)
        first.continuation.finish()
        await connector.waitForConnectionCount(2)
        second.continuation.yield(Self.event("second"))
        await recorder.waitForCount(2)
        await monitor.stop()

        #expect(await recorder.methods == ["first", "second"])
    }

    @Test("indexed lifecycle state avoids redundant start inspection")
    func indexedLifecycleState() {
        #expect(GuestRuntime.requiresStart(.created))
        #expect(!GuestRuntime.requiresStart(.running))
        #expect(GuestRuntime.requiresStart(.exited))
        #expect(
            GuestRuntime.requiresPortPublicationRetry(
                state: .running, publicationPending: true
            )
        )
        #expect(
            !GuestRuntime.requiresPortPublicationRetry(
                state: .running, publicationPending: false
            )
        )
        #expect(
            !GuestRuntime.requiresPortPublicationRetry(
                state: .created, publicationPending: true
            )
        )
    }

    @Test("multiple waiters retain one auto-remove exit result")
    func multipleWaitersShareExitResult() {
        var index = GuestExitCodeIndex()
        index.record(id: "auto-remove", code: 23)

        #expect(index.code(for: "auto-remove") == 23)
        #expect(index.code(for: "auto-remove") == 23)
    }

    @Test("exit result index is bounded")
    func exitResultIndexIsBounded() {
        var index = GuestExitCodeIndex()
        for value in 0...GuestExitCodeIndex.maximumEntries {
            index.record(id: "container-\(value)", code: Int32(value))
        }

        #expect(index.code(for: "container-0") == nil)
        #expect(
            index.code(for: "container-\(GuestExitCodeIndex.maximumEntries)")
                == Int32(GuestExitCodeIndex.maximumEntries)
        )
    }

    @Test("not-found wait recovery is indexed and other errors remain visible")
    func indexedNotFoundRecovery() throws {
        var index = GuestExitCodeIndex()
        index.record(id: "removed", code: 7)

        #expect(
            try index.recoverNotFound(
                id: "removed", error: .notFound("container was auto-removed")
            ) == 7
        )
        #expect(throws: DockerRuntimeRouteError.self) {
            try index.recoverNotFound(id: "missing", error: .notFound("missing"))
        }
        #expect(throws: DockerRuntimeRouteError.self) {
            try index.recoverNotFound(id: "removed", error: .conflict("containerd unavailable"))
        }
    }

    @Test("concurrent waiters issue one guest wait")
    func concurrentWaitersAreSingleFlight() async throws {
        let flights = GuestWaitSingleFlight()
        let probe = GuestWaitProbe()
        async let first = flights.run(id: "container") { await probe.wait() }
        await probe.waitUntilStarted()
        async let second = flights.run(id: "container") { await probe.wait() }
        await Task.yield()
        #expect(await probe.requestCount == 1)

        await probe.complete(code: 17)
        #expect(try await first == 17)
        #expect(try await second == 17)
        #expect(await probe.requestCount == 1)
    }

    @Test("failed wait releases its single-flight entry")
    func failedWaitCanRetry() async throws {
        struct ExpectedFailure: Error {}
        let flights = GuestWaitSingleFlight()
        do {
            _ = try await flights.run(id: "container") { throw ExpectedFailure() }
            Issue.record("failed wait unexpectedly succeeded")
        } catch is ExpectedFailure {}

        let result = try await flights.run(id: "container") { 29 }
        #expect(result == 29)
    }

    @Test("wait before start resumes after successful start")
    func waitBeforeStartSucceeds() async throws {
        let gate = GuestStartGate()
        async let waiting: Void = gate.wait(id: "container")
        await waitForStartWaiter(gate, id: "container")

        await gate.finish(id: "container", result: .success(()))
        try await waiting
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    @Test("start failure resumes all start waiters")
    func startFailureResumesWaiters() async {
        struct StartFailure: Error {}
        let gate = GuestStartGate()
        let waiting = Task { try await gate.wait(id: "container") }
        await waitForStartWaiter(gate, id: "container")

        await gate.finish(id: "container", result: .failure(StartFailure()))
        await #expect(throws: StartFailure.self) { try await waiting.value }
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    @Test("post-start publication failure does not release waiters as success")
    func postStartPublicationFailureResumesWaiters() async {
        struct PublicationFailure: Error {}
        let gate = GuestStartGate()
        let waiting = Task { try await gate.wait(id: "container") }
        await waitForStartWaiter(gate, id: "container")

        // This is the same final failure gate used after the guest has started
        // but host port publication has not committed.
        await gate.finish(id: "container", result: .failure(PublicationFailure()))
        await #expect(throws: PublicationFailure.self) { try await waiting.value }
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    @Test("delete before start resumes waiters as not found")
    func deleteBeforeStartResumesWaiters() async {
        let gate = GuestStartGate()
        let waiting = Task { try await gate.wait(id: "container") }
        await waitForStartWaiter(gate, id: "container")

        await gate.finish(
            id: "container", result: .failure(DockerRuntimeRouteError.notFound("container"))
        )
        await #expect(throws: DockerRuntimeRouteError.self) { try await waiting.value }
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    @Test("canceled start waiter releases its continuation")
    func canceledStartWaiterIsRemoved() async {
        let gate = GuestStartGate()
        let waiting = Task { try await gate.wait(id: "container") }
        await waitForStartWaiter(gate, id: "container")

        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    @Test("removed waiter resumes only after delete cleanup signals")
    func removedWaiterResumesAfterDeleteCleanup() async throws {
        let gate = GuestRemovalGate()
        async let waiting = gate.wait(id: "container")
        await waitForRemovalWaiter(gate, id: "container", count: 1)

        await gate.signal(id: "container", exitCode: 23)
        #expect(try await waiting == 23)
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    @Test("delete signal resumes all removed waiters")
    func deleteSignalResumesAllRemovedWaiters() async throws {
        let gate = GuestRemovalGate()
        async let first = gate.wait(id: "container")
        async let second = gate.wait(id: "container")
        await waitForRemovalWaiter(gate, id: "container", count: 2)

        await gate.signal(id: "container", exitCode: 17)
        #expect(try await first == 17)
        #expect(try await second == 17)
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    @Test("delete signal before waiter registration is retained")
    func deleteSignalBeforeWaiterRegistrationIsRetained() async throws {
        let gate = GuestRemovalGate()
        await gate.signal(id: "container", exitCode: 31)

        #expect(try await gate.wait(id: "container") == 31)
        #expect(try await gate.wait(id: "container") == 31)
    }

    @Test("failed delete does not signal removed waiters")
    func failedDeleteDoesNotSignalRemovedWaiters() async throws {
        let gate = GuestRemovalGate()
        async let waiting = gate.wait(id: "container")
        await waitForRemovalWaiter(gate, id: "container", count: 1)

        // A failed delete does not call signal. The waiter stays registered for
        // a later successful delete.
        await Task.yield()
        #expect(await gate.waiterCount(id: "container") == 1)

        await gate.signal(id: "container", exitCode: 0)
        #expect(try await waiting == 0)
    }

    @Test("canceled removed waiter releases its continuation")
    func canceledRemovedWaiterIsRemoved() async {
        let gate = GuestRemovalGate()
        let waiting = Task { try await gate.wait(id: "container") }
        await waitForRemovalWaiter(gate, id: "container", count: 1)

        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await gate.waiterCount(id: "container") == 0)
    }

    private func waitForStartWaiter(_ gate: GuestStartGate, id: String) async {
        while await gate.waiterCount(id: id) == 0 { await Task.yield() }
    }

    private func waitForRemovalWaiter(_ gate: GuestRemovalGate, id: String, count: Int) async {
        while await gate.waiterCount(id: id) != count { await Task.yield() }
    }

    private static func event(_ method: String) -> GuestFrame {
        GuestFrame(
            id: 0, kind: .event, method: method, payload: .object([:]), stream: nil,
            data: nil, error: nil, exitCode: nil
        )
    }
}

private actor GuestWaitProbe {
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func complete(code: Int32) {
        continuation?.resume(returning: code)
        continuation = nil
    }
}

private actor FakeGuestRuntimeEventConnector: GuestRuntimeEventConnecting {
    private var streams: [AsyncStream<GuestFrame>]
    private(set) var connectionCount = 0

    init(streams: [AsyncStream<GuestFrame>]) {
        self.streams = streams
    }

    func connect() async throws -> AsyncStream<GuestFrame> {
        connectionCount += 1
        return streams.removeFirst()
    }

    func waitForConnectionCount(_ count: Int) async {
        while connectionCount < count { await Task.yield() }
    }
}

private actor GuestRuntimeEventRecorder {
    private(set) var methods: [String] = []

    func record(_ method: String) {
        methods.append(method)
    }

    func waitForCount(_ count: Int) async {
        while methods.count < count { await Task.yield() }
    }
}
