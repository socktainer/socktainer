import Foundation
import Testing

@testable import socktainer

@Suite("FileReaderCache — one open reader per unchanged file")
final class FileReaderCacheTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("repeated use of one file opens it once and hands back the same reader")
    func opensOncePerFile() throws {
        let snapshot = try makeFile("snapshot.ext4", contents: "image layers")
        let opener = CountingOpener()
        let cache = FileReaderCache(capacity: 4, idleTimeout: .seconds(300), open: opener.open)

        let first = try cache.withReader(at: snapshot) { $0 }
        let second = try cache.withReader(at: snapshot) { $0 }

        #expect(opener.opened == [snapshot])
        #expect(first === second)
    }

    @Test("a file replaced at the same path gets a fresh reader")
    func reopensReplacedFile() throws {
        let snapshot = try makeFile("snapshot.ext4", contents: "first pull")
        let opener = CountingOpener()
        let cache = FileReaderCache(capacity: 4, idleTimeout: .seconds(300), open: opener.open)
        let stale = try cache.withReader(at: snapshot) { $0 }

        try FileManager.default.removeItem(atPath: snapshot)
        _ = try makeFile("snapshot.ext4", contents: "second pull")
        let fresh = try cache.withReader(at: snapshot) { $0 }

        #expect(opener.opened == [snapshot, snapshot])
        #expect(stale !== fresh)
    }

    @Test("a deleted file is reported missing rather than served from the cache")
    func refusesDeletedFile() throws {
        let snapshot = try makeFile("snapshot.ext4", contents: "image layers")
        let opener = CountingOpener()
        let cache = FileReaderCache(capacity: 4, idleTimeout: .seconds(300), open: opener.open)
        _ = try cache.withReader(at: snapshot) { $0 }

        try FileManager.default.removeItem(atPath: snapshot)

        #expect(throws: (any Error).self) { try cache.withReader(at: snapshot) { $0 } }
        #expect(opener.opened == [snapshot])
    }

    @Test("a deleted image's reader is released on the next use of the cache")
    func releasesReaderOfDeletedFile() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let redis = try makeFile("redis.ext4", contents: "redis")
        let cache = FileReaderCache(capacity: 4, idleTimeout: .seconds(300), open: CountingOpener().open)
        weak var postgresReader: SnapshotReader?
        try cache.withReader(at: postgres) { postgresReader = $0 }
        #expect(postgresReader != nil)

        try FileManager.default.removeItem(atPath: postgres)
        _ = try cache.withReader(at: redis) { $0 }

        #expect(postgresReader == nil)
    }

    @Test("deleting an image releases its reader without waiting for another use")
    func releasesVanishedFileOnRequest() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let cache = FileReaderCache(capacity: 4, idleTimeout: .seconds(300), open: CountingOpener().open)
        weak var postgresReader: SnapshotReader?
        try cache.withReader(at: postgres) { postgresReader = $0 }

        try FileManager.default.removeItem(atPath: postgres)
        cache.releaseVanishedFiles()

        #expect(postgresReader == nil)
    }

    @Test("a reader left unused for the idle timeout is closed, a recent one is kept")
    func closesIdleReaders() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let redis = try makeFile("redis.ext4", contents: "redis")
        let clock = ManualClock()
        let cache = FileReaderCache(
            capacity: 4, idleTimeout: .seconds(300), now: clock.now, open: CountingOpener().open)
        weak var postgresReader: SnapshotReader?
        weak var redisReader: SnapshotReader?
        try cache.withReader(at: postgres) { postgresReader = $0 }
        clock.advance(by: .seconds(200))
        try cache.withReader(at: redis) { redisReader = $0 }

        clock.advance(by: .seconds(100))
        cache.releaseIdleReaders()

        #expect(postgresReader == nil)
        #expect(redisReader != nil)
    }

    @Test("a reader in use is not closed for idleness")
    func keepsReaderInUse() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let clock = ManualClock()
        let opener = CountingOpener()
        let cache = FileReaderCache(capacity: 4, idleTimeout: .seconds(300), now: clock.now, open: opener.open)

        try cache.withReader(at: postgres) { _ in
            clock.advance(by: .seconds(600))
            cache.releaseIdleReaders()
        }
        _ = try cache.withReader(at: postgres) { $0 }

        #expect(opener.opened == [postgres])
    }

    @Test("uses within one idle period share a single pending idle release")
    func schedulesOneIdleReleaseAtATime() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let scheduler = ManualScheduler()
        let cache = FileReaderCache(
            capacity: 4, idleTimeout: .seconds(300), scheduleAfter: scheduler.schedule,
            open: CountingOpener().open)

        for _ in 0..<3 {
            _ = try cache.withReader(at: postgres) { $0 }
        }

        #expect(scheduler.pendingCount == 1)
    }

    @Test("the idle release re-arms while readers stay cached and stops once none are left")
    func idleReleaseRearmsUntilCacheIsEmpty() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let clock = ManualClock()
        let scheduler = ManualScheduler()
        let cache = FileReaderCache(
            capacity: 4, idleTimeout: .seconds(300), now: clock.now, scheduleAfter: scheduler.schedule,
            open: CountingOpener().open)
        weak var postgresReader: SnapshotReader?
        try cache.withReader(at: postgres) { postgresReader = $0 }

        clock.advance(by: .seconds(100))
        scheduler.runPending()
        #expect(postgresReader != nil)
        #expect(scheduler.pendingCount == 1)

        clock.advance(by: .seconds(200))
        scheduler.runPending()
        #expect(postgresReader == nil)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("the idle release re-arms for the time the oldest reader still has before going idle")
    func rearmsForEarliestExpiry() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let clock = ManualClock()
        let scheduler = ManualScheduler()
        let cache = FileReaderCache(
            capacity: 4, idleTimeout: .seconds(300), now: clock.now, scheduleAfter: scheduler.schedule,
            open: CountingOpener().open)
        _ = try cache.withReader(at: postgres) { $0 }

        clock.advance(by: .seconds(100))
        scheduler.runPending()

        #expect(scheduler.scheduledDelays == [.seconds(300), .seconds(200)])
    }

    @Test("an idle release firing while a reader is in use waits a full idle timeout again")
    func idleReleaseDuringUseWaitsFullTimeout() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let clock = ManualClock()
        let scheduler = ManualScheduler()
        let opener = CountingOpener()
        let cache = FileReaderCache(
            capacity: 4, idleTimeout: .seconds(300), now: clock.now, scheduleAfter: scheduler.schedule,
            open: opener.open)
        _ = try cache.withReader(at: postgres) { $0 }
        clock.advance(by: .seconds(300))

        try cache.withReader(at: postgres) { _ in scheduler.runPending() }

        #expect(scheduler.scheduledDelays == [.seconds(300), .seconds(300)])
        #expect(opener.opened == [postgres])
    }

    @Test("a reader that fails to open gives its slot back")
    func failedOpenFreesItsSlot() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let corrupt = try makeFile("corrupt.ext4", contents: "not an ext4 image")
        let redis = try makeFile("redis.ext4", contents: "redis")
        let opener = CountingOpener(failing: [corrupt])
        let cache = FileReaderCache(capacity: 2, idleTimeout: .seconds(300), open: opener.open)

        _ = try cache.withReader(at: postgres) { $0 }
        #expect(throws: (any Error).self) { try cache.withReader(at: corrupt) { $0 } }
        _ = try cache.withReader(at: redis) { $0 }
        _ = try cache.withReader(at: postgres) { $0 }

        #expect(opener.opened == [postgres, corrupt, redis])
    }

    @Test("a reader in use is not evicted, so its next user does not open the file again")
    func keepsInUseReaderPastCapacity() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let redis = try makeFile("redis.ext4", contents: "redis")
        let opener = CountingOpener()
        let cache = FileReaderCache(capacity: 1, idleTimeout: .seconds(300), open: opener.open)

        try cache.withReader(at: postgres) { _ in
            _ = try cache.withReader(at: redis) { $0 }
        }
        _ = try cache.withReader(at: postgres) { $0 }

        #expect(opener.opened == [postgres, redis])
    }

    @Test("past capacity the least recently used reader is dropped")
    func evictsLeastRecentlyUsed() throws {
        let postgres = try makeFile("postgres.ext4", contents: "postgres")
        let redis = try makeFile("redis.ext4", contents: "redis")
        let localstack = try makeFile("localstack.ext4", contents: "localstack")
        let opener = CountingOpener()
        let cache = FileReaderCache(capacity: 2, idleTimeout: .seconds(300), open: opener.open)

        _ = try cache.withReader(at: postgres) { $0 }
        _ = try cache.withReader(at: redis) { $0 }
        _ = try cache.withReader(at: postgres) { $0 }
        _ = try cache.withReader(at: localstack) { $0 }
        _ = try cache.withReader(at: postgres) { $0 }
        _ = try cache.withReader(at: redis) { $0 }

        #expect(opener.opened == [postgres, redis, localstack, redis])
    }

    @Test("concurrent users of one reader take turns and share a single open")
    func serializesConcurrentUse() throws {
        let snapshot = try makeFile("snapshot.ext4", contents: "image layers")
        let opener = CountingOpener()
        let cache = FileReaderCache(capacity: 4, idleTimeout: .seconds(300), open: opener.open)
        let occupancy = Occupancy()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            _ = try? cache.withReader(at: snapshot) { _ in
                occupancy.enter()
                Thread.sleep(forTimeInterval: 0.002)
                occupancy.leave()
            }
        }

        #expect(occupancy.peak == 1)
        #expect(opener.opened == [snapshot])
    }

    private func makeFile(_ name: String, contents: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url.path
    }
}

private final class SnapshotReader {
    let path: String
    init(path: String) { self.path = path }
}

private final class CountingOpener: @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Set<String>
    private var paths: [String] = []

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var opened: [String] { lock.withLock { paths } }

    func open(_ path: String) throws -> SnapshotReader {
        lock.withLock { paths.append(path) }
        if failing.contains(path) { throw CocoaError(.fileReadCorruptFile) }
        return SnapshotReader(path: path)
    }
}

private final class Occupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var highest = 0

    var peak: Int { lock.withLock { highest } }

    func enter() {
        lock.withLock {
            current += 1
            highest = max(highest, current)
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    func now() -> ContinuousClock.Instant {
        lock.withLock { current }
    }

    func advance(by duration: Duration) {
        lock.withLock { current += duration }
    }
}

private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    private var delays: [Duration] = []

    var pendingCount: Int { lock.withLock { pending.count } }
    var scheduledDelays: [Duration] { lock.withLock { delays } }

    func schedule(_ delay: Duration, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            pending.append(work)
            delays.append(delay)
        }
    }

    func runPending() {
        let due = lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
        due.forEach { $0() }
    }
}
