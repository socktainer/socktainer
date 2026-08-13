import CoreServices
import Foundation
import Logging
import Vapor

struct BindHostChangeBatch: Sendable, Equatable {
    static let maximumPaths = 4_096

    var paths: Set<String> = []
    var invalidateAll = false

    mutating func formUnion(_ other: Self) {
        if invalidateAll || other.invalidateAll {
            paths.removeAll(keepingCapacity: false)
            invalidateAll = true
            return
        }
        paths.formUnion(other.paths)
        if paths.count > Self.maximumPaths {
            paths.removeAll(keepingCapacity: false)
            invalidateAll = true
        }
    }
}

protocol BindHostEventSource: Sendable {
    func start(_ handler: @escaping @Sendable (BindHostChangeBatch) -> Void) throws
    func flush() throws -> BindHostChangeBatch
    func stop()
}

protocol BindCacheGuestSink: Sendable {
    func invalidate(paths: Set<String>, all: Bool, barrierID: UInt64?) async throws
}

/// Orders host filesystem changes before guest cache-barrier acknowledgements.
actor BindCacheInvalidationController {
    private let source: any BindHostEventSource
    private let sink: any BindCacheGuestSink
    private let logger: Logger
    private var started = false

    init(
        source: any BindHostEventSource,
        sink: any BindCacheGuestSink,
        logger: Logger = Logger(label: "socktainer.bind-cache")
    ) {
        self.source = source
        self.sink = sink
        self.logger = logger
    }

    func start() throws {
        guard !started else { return }
        try source.start { [weak self] batch in
            Task { await self?.receive(batch) }
        }
        started = true
    }

    func stop() {
        guard started else { return }
        source.stop()
        started = false
    }

    func writeBarrier(id: UInt64, guestPaths: Set<String>, invalidateAll: Bool = false) async throws {
        // flush() synchronously delivers every FSEvent through the stream's
        // current point and drains the event source's retained batch. This actor
        // cannot acknowledge the barrier until the guest completes invalidation.
        var batch = try source.flush()
        batch.formUnion(.init(paths: guestPaths, invalidateAll: invalidateAll))
        if batch.paths.isEmpty && !batch.invalidateAll {
            batch.invalidateAll = true
        }
        try await sink.invalidate(paths: batch.paths, all: batch.invalidateAll, barrierID: id)
    }

    private func receive(_ batch: BindHostChangeBatch) async {
        guard batch.invalidateAll || !batch.paths.isEmpty else { return }
        do {
            try await sink.invalidate(paths: batch.paths, all: batch.invalidateAll, barrierID: nil)
        } catch {
            logger.error("failed to invalidate the guest bind cache", metadata: ["error": "\(error)"])
        }
    }
}

final class FSEventsBindHostEventSource: BindHostEventSource, @unchecked Sendable {
    private let root: URL
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "socktainer.bind-cache.fsevents")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable (BindHostChangeBatch) -> Void)?
    private var pending = BindHostChangeBatch()

    init(root: URL, latency: CFTimeInterval = 0.01) {
        self.root = root.standardizedFileURL
        self.latency = latency
    }

    func start(_ handler: @escaping @Sendable (BindHostChangeBatch) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, context, count, paths, flags, _ in
            guard let context else { return }
            let source = Unmanaged<FSEventsBindHostEventSource>.fromOpaque(context).takeUnretainedValue()
            source.record(count: count, paths: paths, flags: flags)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard
            let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        else {
            throw CocoaError(.fileReadUnknown)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            self.stream = nil
            self.handler = nil
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw CocoaError(.fileReadUnknown)
        }
    }

    func flush() throws -> BindHostChangeBatch {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        guard let stream else { throw CocoaError(.fileReadUnknown) }

        // The callback must not need the lock while this synchronous flush waits.
        FSEventStreamFlushSync(stream)
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = BindHostChangeBatch()
        return result
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        handler = nil
        pending = BindHostChangeBatch()
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }

    private func record(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        // UseCFTypes guarantees a borrowed CFArray of CFString values here.
        let eventPaths = unsafeBitCast(paths, to: NSArray.self) as! [String]
        var batch = BindHostChangeBatch()
        for index in 0..<count {
            let flag = flags[index]
            if Self.requiresFullInvalidation(flag) {
                batch.invalidateAll = true
                continue
            }
            let path = URL(fileURLWithPath: eventPaths[index]).standardizedFileURL.path
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard path.hasPrefix(prefix) else {
                batch.invalidateAll = true
                continue
            }
            batch.formUnion(
                .init(paths: [String(path.dropFirst(prefix.count))], invalidateAll: false)
            )
        }

        lock.lock()
        pending.formUnion(batch)
        let handler = self.handler
        lock.unlock()
        handler?(batch)
    }

    private static func requiresFullInvalidation(_ flags: FSEventStreamEventFlags) -> Bool {
        let invalidatingFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        return flags & invalidatingFlags != 0
    }
}

struct GuestConnectionBindCacheSink: BindCacheGuestSink {
    let engine: PersistentEngine

    func invalidate(paths: Set<String>, all: Bool, barrierID: UInt64?) async throws {
        _ = try await engine.readyConnection().request(
            method: "bind.invalidate",
            payload: .object(Self.payload(paths: paths, all: all, barrierID: barrierID))
        )
    }

    static func payload(paths: Set<String>, all: Bool, barrierID: UInt64?) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "paths": .array(paths.sorted().map(JSONValue.string)),
            "all": .bool(all),
        ]
        if let barrierID {
            payload["barrierId"] = .string(String(barrierID))
        }
        return payload
    }
}

protocol BindCacheGuestEventConnecting: Sendable {
    func connect() async throws -> AsyncStream<GuestFrame>
}

actor PersistentEngineBindCacheEventConnector: BindCacheGuestEventConnecting {
    private let engine: PersistentEngine
    private var previous: GuestConnection?

    init(engine: PersistentEngine) {
        self.engine = engine
    }

    func connect() async throws -> AsyncStream<GuestFrame> {
        if let previous {
            await engine.invalidateConnection(previous)
        }
        let connection = try await engine.readyConnection()
        previous = connection
        return await connection.events()
    }
}

actor GuestBindCacheBridge {
    private let events: any BindCacheGuestEventConnecting
    private let controller: BindCacheInvalidationController
    private var task: Task<Void, Never>?
    private var reconnect = true

    init(events: any BindCacheGuestEventConnecting, controller: BindCacheInvalidationController) {
        self.events = events
        self.controller = controller
    }

    func start() async throws {
        guard task == nil else { return }
        try await controller.start()
        reconnect = true
        let initialEvents = try await events.connect()
        task = Task { [weak self] in
            await self?.monitor(initialEvents)
        }
    }

    func stop() async {
        reconnect = false
        task?.cancel()
        task = nil
        await controller.stop()
    }

    func disableReconnect() {
        reconnect = false
    }

    private func handle(_ event: GuestFrame) async {
        guard case .object(let payload) = event.payload,
            case .string(let rawID) = payload["barrierId"],
            let barrierID = UInt64(rawID),
            case .array(let rawPaths) = payload["paths"]
        else { return }
        var paths: Set<String> = []
        var invalidateAll = false
        for value in rawPaths {
            guard case .string(let path) = value, Self.validGuestPath(path) else {
                invalidateAll = true
                continue
            }
            paths.insert(path)
        }
        do {
            try await controller.writeBarrier(id: barrierID, guestPaths: paths, invalidateAll: invalidateAll)
        } catch {
            // The guest keeps the barrier closed and returns EIO on its timeout.
        }
    }

    private func monitor(_ initialEvents: AsyncStream<GuestFrame>) async {
        var stream = initialEvents
        while !Task.isCancelled {
            for await event in stream where event.method == "bind.write.barrier" {
                await handle(event)
            }
            guard !Task.isCancelled, reconnect else { return }
            do {
                stream = try await events.connect()
            } catch {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private static func validGuestPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

struct GuestBindCacheEngineLifecycle: LifecycleHandler {
    let bridge: GuestBindCacheBridge
    let engine: PersistentEngine

    func shutdownAsync(_ application: Application) async {
        // Do not interpret the expected connection close as a reason to boot the
        // engine again. Keep the current event stream alive for engine.sync.
        await bridge.disableReconnect()
        await engine.shutdown()
        await bridge.stop()
    }
}
