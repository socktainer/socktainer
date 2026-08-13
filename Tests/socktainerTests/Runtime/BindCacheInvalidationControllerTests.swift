import Foundation
import Testing

@testable import socktainer

@Suite("Bind cache invalidation ordering")
struct BindCacheInvalidationControllerTests {
    @Test("a host write before a barrier is invalidated before acknowledgement")
    func hostWriteBeforeBarrier() async throws {
        let source = FakeBindHostEventSource()
        let sink = RecordingBindCacheGuestSink()
        let controller = BindCacheInvalidationController(source: source, sink: sink)
        try await controller.start()

        source.record(.init(paths: ["work/data"], invalidateAll: false), notify: false)
        try await controller.writeBarrier(id: 7, guestPaths: [])

        let calls = await sink.calls
        #expect(calls.last == .init(paths: ["work/data"], all: false, barrierID: 7))
    }

    @Test("a host write after a barrier causes another invalidation")
    func hostWriteAfterBarrier() async throws {
        let source = FakeBindHostEventSource()
        let sink = RecordingBindCacheGuestSink()
        let controller = BindCacheInvalidationController(source: source, sink: sink)
        try await controller.start()
        try await controller.writeBarrier(id: 8, guestPaths: ["guest/file"])

        source.record(.init(paths: ["host/file"], invalidateAll: false))
        await sink.waitForCallCount(2)

        let calls = await sink.calls
        #expect(calls[0] == .init(paths: ["guest/file"], all: false, barrierID: 8))
        #expect(calls[1] == .init(paths: ["host/file"], all: false, barrierID: nil))
    }

    @Test("event loss and root changes invalidate the full cache")
    func lossInvalidatesAll() async throws {
        let source = FakeBindHostEventSource()
        let sink = RecordingBindCacheGuestSink()
        let controller = BindCacheInvalidationController(source: source, sink: sink)
        try await controller.start()

        source.record(.init(paths: [], invalidateAll: true), notify: false)
        try await controller.writeBarrier(id: 9, guestPaths: [])

        #expect(await sink.calls == [.init(paths: [], all: true, barrierID: 9)])
    }

    @Test("no event through the flush point can cross the barrier acknowledgement")
    func noEventCrossesAcknowledgement() async throws {
        let source = FakeBindHostEventSource()
        let sink = RecordingBindCacheGuestSink()
        let controller = BindCacheInvalidationController(source: source, sink: sink)
        try await controller.start()
        source.onFlush = {
            source.record(.init(paths: ["concurrent/write"], invalidateAll: false), notify: false)
        }

        try await controller.writeBarrier(id: 10, guestPaths: ["guest/write"])

        let calls = await sink.calls
        #expect(calls == [.init(paths: ["concurrent/write", "guest/write"], all: false, barrierID: 10)])
    }

    @Test("an oversized retained path batch becomes a full invalidation")
    func oversizedBatchInvalidatesAll() {
        var batch = BindHostChangeBatch()
        batch.formUnion(
            .init(
                paths: Set((0...BindHostChangeBatch.maximumPaths).map { "file-\($0)" }),
                invalidateAll: false
            )
        )

        #expect(batch.invalidateAll)
        #expect(batch.paths.isEmpty)
    }

    @Test("the wire payload preserves the maximum barrier ID as a decimal string")
    func maximumBarrierIDWireEncoding() {
        let payload = GuestConnectionBindCacheSink.payload(
            paths: ["work/file"], all: false, barrierID: UInt64.max
        )

        #expect(payload["barrierId"] == .string("18446744073709551615"))
    }

    @Test("the bridge subscribes again after its guest event connection ends")
    func bridgeReconnects() async throws {
        let first = AsyncStream<GuestFrame>.makeStream()
        let second = AsyncStream<GuestFrame>.makeStream()
        let events = FakeBindCacheGuestEventConnector(streams: [first.stream, second.stream])
        let source = FakeBindHostEventSource()
        let sink = RecordingBindCacheGuestSink()
        let controller = BindCacheInvalidationController(source: source, sink: sink)
        let bridge = GuestBindCacheBridge(events: events, controller: controller)
        try await bridge.start()

        first.continuation.yield(Self.barrierEvent(id: 1, path: "first"))
        await sink.waitForCallCount(1)
        first.continuation.finish()
        await events.waitForConnectionCount(2)
        second.continuation.yield(Self.barrierEvent(id: UInt64.max, path: "second"))
        await sink.waitForCallCount(2)
        await bridge.stop()

        let calls = await sink.calls
        #expect(calls[0] == .init(paths: ["first"], all: false, barrierID: 1))
        #expect(calls[1] == .init(paths: ["second"], all: false, barrierID: UInt64.max))
    }

    private static func barrierEvent(id: UInt64, path: String) -> GuestFrame {
        GuestFrame(
            id: 0,
            kind: .event,
            method: "bind.write.barrier",
            payload: .object([
                "barrierId": .string(String(id)),
                "paths": .array([.string(path)]),
            ]),
            stream: nil,
            data: nil,
            error: nil,
            exitCode: nil
        )
    }
}

private final class FakeBindHostEventSource: BindHostEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = BindHostChangeBatch()
    private var handler: (@Sendable (BindHostChangeBatch) -> Void)?
    var onFlush: (@Sendable () -> Void)?

    func start(_ handler: @escaping @Sendable (BindHostChangeBatch) -> Void) throws {
        lock.withLock { self.handler = handler }
    }

    func flush() throws -> BindHostChangeBatch {
        onFlush?()
        return lock.withLock {
            let result = pending
            pending = .init()
            return result
        }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func record(_ batch: BindHostChangeBatch, notify: Bool = true) {
        let handler = lock.withLock {
            pending.formUnion(batch)
            return self.handler
        }
        if notify { handler?(batch) }
    }
}

private actor FakeBindCacheGuestEventConnector: BindCacheGuestEventConnecting {
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
        while connectionCount < count {
            await Task.yield()
        }
    }
}

private actor RecordingBindCacheGuestSink: BindCacheGuestSink {
    struct Call: Sendable, Equatable {
        let paths: Set<String>
        let all: Bool
        let barrierID: UInt64?
    }

    private(set) var calls: [Call] = []

    func invalidate(paths: Set<String>, all: Bool, barrierID: UInt64?) async throws {
        calls.append(.init(paths: paths, all: all, barrierID: barrierID))
    }

    func waitForCallCount(_ count: Int) async {
        while calls.count < count {
            await Task.yield()
        }
    }
}
