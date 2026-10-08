import ContainerAPIClient
import ContainerResource
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import socktainer

/// A running guest buffers writes in its page cache, so `rootfs.ext4` read from the
/// host lags behind. The service must flush the guest before reading a running
/// container, and must leave stopped containers alone (no guest to flush).
///
/// The flush is injected: the fake stands in for the guest's write-back by adding the
/// "fresh" file to the image the moment it is called. A read that happens before the
/// flush therefore cannot see the file.
@Suite("ClientArchiveService flushes a running guest before reading its rootfs")
struct ClientArchiveServiceFlushTests {

    @Test("getArchive on a running container sees a file the guest wrote just before the call")
    func getArchiveSeesFreshFile() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let service = fixture.service(writebackOf: ["/out.txt": "fresh\n"], intoContainer: "web")

        let (tarData, stat) = try await service.getArchive(
            container: fixture.makeContainer(id: "web", status: .running), path: "/out.txt")

        #expect(stat.name == "out.txt")
        #expect(!tarData.isEmpty)
        #expect(fixture.flushCalls.count == 1)
    }

    @Test("statPath on a running container sees a file the guest wrote just before the call")
    func statPathSeesFreshFile() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let service = fixture.service(writebackOf: ["/out.txt": "fresh\n"], intoContainer: "web")

        let stat = try await service.statPath(
            container: fixture.makeContainer(id: "web", status: .running), path: "/out.txt")

        #expect(stat.name == "out.txt")
        #expect(stat.size == 6)
        #expect(fixture.flushCalls.count == 1)
    }

    @Test("a stopped container is read as-is without flushing")
    func stoppedContainerIsNotFlushed() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let service = fixture.service(writebackOf: ["/out.txt": "fresh\n"], intoContainer: "web")
        let stopped = fixture.makeContainer(id: "web", status: .stopped)

        _ = try await service.getArchive(container: stopped, path: "/hello.txt")
        _ = try await service.statPath(container: stopped, path: "/hello.txt")

        #expect(fixture.flushCalls.count == 0)
    }

    @Test("a flush that never returns does not hold getArchive or statPath past the cap")
    func stuckFlushIsCapped() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let stuck = StuckWait()
        defer { stuck.release() }
        let service = fixture.service(flushTimeout: .milliseconds(100)) { _ in await stuck.wait() }
        let running = fixture.makeContainer(id: "web", status: .running)

        let reads = ReadResults()
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(10)) {
            reads.archive = try? await service.getArchive(container: running, path: "/hello.txt").stat
            reads.stat = try? await service.statPath(container: running, path: "/hello.txt")
        }

        #expect(finished, "the reads waited on a flush that never returns")
        #expect(reads.archive?.size == 3)
        #expect(reads.stat?.size == 3)
    }

    @Test("a flush that fails (e.g. no /bin/sync in the image) still reads what is on disk")
    func failedFlushReadsOnDisk() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let service = fixture.service(flushTimeout: .seconds(5)) { _ in throw FlushFailure() }
        let running = fixture.makeContainer(id: "web", status: .running)

        let (_, archiveStat) = try await service.getArchive(container: running, path: "/hello.txt")
        let stat = try await service.statPath(container: running, path: "/hello.txt")

        #expect(archiveStat.size == 3)
        #expect(stat.size == 3)
    }
}

@Suite("ClientArchiveService.boundedFlush caps a flush that does not return")
struct ClientArchiveServiceBoundedFlushTests {

    @Test("a flush that never returns (and ignores cancellation) times out within the bound")
    func neverReturningFlushTimesOut() async {
        let stuck = StuckWait()
        defer { stuck.release() }
        let result = OutcomeBox()
        let clock = ContinuousClock()
        let start = clock.now

        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(10)) {
            result.outcome = await ClientArchiveService.boundedFlush(timeout: .milliseconds(100)) {
                await stuck.wait()
            }
        }

        #expect(finished, "boundedFlush waited on a flush that never returns")
        // Far below the 10 s watchdog: it did not wait on the parked flush.
        #expect(clock.now - start < .seconds(8))
        guard case .timedOut = result.outcome else {
            Issue.record("expected .timedOut, got \(String(describing: result.outcome))")
            return
        }
    }

    @Test("a flush that returns quickly reports flushed")
    func quickFlushReportsFlushed() async {
        let outcome = await ClientArchiveService.boundedFlush(timeout: .seconds(5)) {}
        guard case .flushed = outcome else {
            Issue.record("expected .flushed, got \(outcome)")
            return
        }
    }

    @Test("a flush that throws reports failed")
    func throwingFlushReportsFailed() async {
        let outcome = await ClientArchiveService.boundedFlush(timeout: .seconds(5)) { throw FlushFailure() }
        guard case .failed(let error) = outcome, error is FlushFailure else {
            Issue.record("expected .failed(FlushFailure), got \(outcome)")
            return
        }
    }
}

@Suite("ClientArchiveService skips the flush while an abandoned flush is still running")
struct ClientArchiveServiceFlushBreakerTests {

    @Test("50 reads of a wedged running container run one flush and each returns within the bound")
    func wedgedContainerFlushesOnce() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let stuck = StuckWait()
        defer { stuck.release() }
        let calls = fixture.flushCalls
        let service = fixture.wedgedService(stuck: stuck)
        let running = fixture.makeContainer(id: "web", status: .running)

        let slowest = DurationBox()
        let sizes = SizeLog()
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(20)) {
            @Sendable func read(_ index: Int) async {
                let clock = ContinuousClock()
                let start = clock.now
                let size: Int64?
                if index.isMultiple(of: 2) {
                    size = try? await service.statPath(container: running, path: "/hello.txt").size
                } else {
                    size = try? await service.getArchive(container: running, path: "/hello.txt").stat.size
                }
                slowest.record(clock.now - start)
                sizes.record(size)
            }
            // The first read times out and trips the breaker; the rest arrive while the
            // abandoned flush is still parked, some one after another, some at once.
            for index in 0..<10 { await read(index) }
            await withTaskGroup(of: Void.self) { group in
                for index in 10..<50 { group.addTask { await read(index) } }
            }
        }

        #expect(finished, "the reads waited on a flush that never returns")
        #expect(calls.count == 1)
        #expect(sizes.values.count == 50)
        #expect(sizes.values.allSatisfy { $0 == 3 })
        // Far below the 20 s watchdog: no read waited on the parked flush.
        #expect(slowest.value < .seconds(10))
    }

    @Test("once the abandoned flush returns, the next read flushes again")
    func flushesAgainAfterAbandonedFlushReturns() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let stuck = StuckWait()
        defer { stuck.release() }
        let calls = fixture.flushCalls
        let breaker = GuestFlushBreaker()
        let service = fixture.wedgedService(stuck: stuck, breaker: breaker)
        let running = fixture.makeContainer(id: "web", status: .running)

        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(10)) {
            _ = try? await service.statPath(container: running, path: "/hello.txt")
            _ = try? await service.getArchive(container: running, path: "/hello.txt")
        }
        #expect(finished)
        #expect(calls.count == 1)
        #expect(breaker.isTripped(containerId: "web"))

        stuck.release()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while breaker.isTripped(containerId: "web") && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!breaker.isTripped(containerId: "web"), "the returned flush did not untrip the container")

        _ = try await service.statPath(container: running, path: "/hello.txt")
        #expect(calls.count == 2)
    }

    @Test("a wedged container does not stop another container from flushing")
    func otherContainerUnaffected() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        try fixture.writeRootfs(containerId: "api", files: ["/hello.txt": "hi\n"])
        let stuck = StuckWait()
        defer { stuck.release() }
        let calls = fixture.flushCalls
        let breaker = GuestFlushBreaker()
        // One breaker, two services: `web` parks forever and times out once entered,
        // which trips it; `api` returns at once under a cap it cannot miss, so whether
        // it is flushed depends only on the breaker keeping the containers apart.
        let wedged = fixture.wedgedService(stuck: stuck, breaker: breaker)
        let healthy = fixture.service(flushTimeout: .seconds(60), breaker: breaker) { container in
            calls.record(container.id)
        }
        let web = fixture.makeContainer(id: "web", status: .running)
        let api = fixture.makeContainer(id: "api", status: .running)

        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(30)) {
            for _ in 0..<3 {
                _ = try? await wedged.statPath(container: web, path: "/hello.txt")
                _ = try? await healthy.getArchive(container: api, path: "/hello.txt")
            }
        }

        #expect(finished)
        #expect(breaker.isTripped(containerId: "web"))
        #expect(!breaker.isTripped(containerId: "api"))
        #expect(calls.count(of: "web") == 1)
        #expect(calls.count(of: "api") == 3)
    }

    @Test("a wedged container gets one probe flush per re-arm interval")
    func wedgedContainerProbesOncePerInterval() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let stuck = StuckWait()
        defer { stuck.release() }
        let calls = fixture.flushCalls
        let clock = ManualClock()
        let breaker = GuestFlushBreaker(reArmInterval: .seconds(60), now: clock.now)
        let service = fixture.wedgedService(stuck: stuck, breaker: breaker)
        let running = fixture.makeContainer(id: "web", status: .running)
        let counts = CountLog()

        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(30)) {
            // Trips, then skips while the trip is fresh.
            _ = try? await service.statPath(container: running, path: "/hello.txt")
            _ = try? await service.getArchive(container: running, path: "/hello.txt")
            clock.advance(by: .seconds(59))
            _ = try? await service.getArchive(container: running, path: "/hello.txt")
            counts.record(calls.count)
            // The interval has passed: one probe, which parks too and trips again.
            clock.advance(by: .seconds(1))
            _ = try? await service.statPath(container: running, path: "/hello.txt")
            _ = try? await service.getArchive(container: running, path: "/hello.txt")
            counts.record(calls.count)
            // And again one interval after the probe was abandoned.
            clock.advance(by: .seconds(60))
            _ = try? await service.getArchive(container: running, path: "/hello.txt")
            counts.record(calls.count)
        }

        #expect(finished, "the reads waited on a flush that never returns")
        #expect(counts.values == [1, 2, 3])
        #expect(breaker.isTripped(containerId: "web"))
    }

    @Test("a container restarted with the same id flushes again once its trip expires")
    func restartedContainerFlushesAfterReArm() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let calls = fixture.flushCalls
        let clock = ManualClock()
        let breaker = GuestFlushBreaker(reArmInterval: .seconds(60), now: clock.now)
        // The earlier guest's sync never returned and never will.
        let orphan = try #require(breaker.begin(containerId: "web"))
        #expect(breaker.abandon(orphan))
        let service = fixture.service(flushTimeout: .seconds(60), breaker: breaker) { container in
            calls.record(container.id)
        }
        let running = fixture.makeContainer(id: "web", status: .running)

        _ = try await service.statPath(container: running, path: "/hello.txt")
        #expect(calls.count == 0)

        clock.advance(by: .seconds(60))
        _ = try await service.statPath(container: running, path: "/hello.txt")
        #expect(calls.count == 1)
        #expect(!breaker.isTripped(containerId: "web"), "a probe that returned did not untrip the container")

        _ = try await service.getArchive(container: running, path: "/hello.txt")
        #expect(calls.count == 2)
    }

    @Test("a stopped container is never flushed, wedged or not")
    func stoppedContainerNeverFlushed() async throws {
        let fixture = FlushFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/hello.txt": "hi\n"])
        let stuck = StuckWait()
        defer { stuck.release() }
        let calls = fixture.flushCalls
        let service = fixture.wedgedService(stuck: stuck)
        let stopped = fixture.makeContainer(id: "web", status: .stopped)

        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(10)) {
            _ = try? await service.statPath(container: stopped, path: "/hello.txt")
            _ = try? await service.statPath(
                container: fixture.makeContainer(id: "web", status: .running), path: "/hello.txt")
            _ = try? await service.getArchive(container: stopped, path: "/hello.txt")
            _ = try? await service.statPath(container: stopped, path: "/hello.txt")
        }

        #expect(finished)
        #expect(calls.count == 1)
    }

    @Test("a flush that returned before the read gave up does not trip the container")
    func finishBeforeAbandonDoesNotTrip() throws {
        let breaker = GuestFlushBreaker()
        let attempt = try #require(breaker.begin(containerId: "web"))
        breaker.finish(attempt)

        #expect(!breaker.abandon(attempt))
        #expect(!breaker.isTripped(containerId: "web"))
    }

    @Test("a tripped container skips until the re-arm interval, then gets exactly one probe")
    func tripExpiresIntoOneProbe() throws {
        let clock = ManualClock()
        let breaker = GuestFlushBreaker(reArmInterval: .seconds(60), now: clock.now)
        let first = try #require(breaker.begin(containerId: "web"))
        #expect(!first.isProbe)
        #expect(breaker.abandon(first))

        clock.advance(by: .seconds(59))
        #expect(breaker.isTripped(containerId: "web"))
        #expect(breaker.begin(containerId: "web") == nil)

        clock.advance(by: .seconds(1))
        #expect(!breaker.isTripped(containerId: "web"))
        let probe = try #require(breaker.begin(containerId: "web"))
        #expect(probe.isProbe)
        // Granting the probe renews the trip: concurrent reads keep skipping.
        #expect(breaker.isTripped(containerId: "web"))
        #expect(breaker.begin(containerId: "web") == nil)
    }

    @Test("a probe that times out trips the container again from that moment")
    func abandonedProbeRenewsTrip() throws {
        let clock = ManualClock()
        let breaker = GuestFlushBreaker(reArmInterval: .seconds(60), now: clock.now)
        let first = try #require(breaker.begin(containerId: "web"))
        breaker.abandon(first)
        clock.advance(by: .seconds(60))
        let probe = try #require(breaker.begin(containerId: "web"))

        clock.advance(by: .seconds(30))
        #expect(breaker.abandon(probe))
        clock.advance(by: .seconds(59))
        #expect(breaker.begin(containerId: "web") == nil)
        clock.advance(by: .seconds(1))
        #expect(breaker.begin(containerId: "web")?.isProbe == true)
    }

    @Test("a probe that returns untrips the container although the original flush never returned")
    func returnedProbeClearsTrip() throws {
        let clock = ManualClock()
        let breaker = GuestFlushBreaker(reArmInterval: .seconds(60), now: clock.now)
        let orphan = try #require(breaker.begin(containerId: "web"))
        breaker.abandon(orphan)
        clock.advance(by: .seconds(60))
        let probe = try #require(breaker.begin(containerId: "web"))

        breaker.finish(probe)
        #expect(!breaker.abandon(probe))
        #expect(!breaker.isTripped(containerId: "web"))
        #expect(breaker.begin(containerId: "web")?.isProbe == false)

        // The orphan returning much later changes nothing.
        breaker.finish(orphan)
        #expect(!breaker.isTripped(containerId: "web"))
    }

    @Test("an orphan of an earlier trip returning late does not untrip a later trip")
    func lateOrphanDoesNotClearLaterTrip() throws {
        let clock = ManualClock()
        let breaker = GuestFlushBreaker(reArmInterval: .seconds(60), now: clock.now)
        // First trip: the orphan never returned, then a probe returned and ended it.
        let orphan = try #require(breaker.begin(containerId: "web"))
        #expect(breaker.abandon(orphan))
        clock.advance(by: .seconds(60))
        let probe = try #require(breaker.begin(containerId: "web"))
        breaker.finish(probe)
        #expect(!breaker.isTripped(containerId: "web"))

        // Second trip, from a new timeout.
        let later = try #require(breaker.begin(containerId: "web"))
        #expect(breaker.abandon(later))

        // The orphan of the first trip returns: says nothing about the second.
        breaker.finish(orphan)
        #expect(breaker.isTripped(containerId: "web"), "an orphan of an ended trip cleared a later one")
        #expect(breaker.begin(containerId: "web") == nil)

        breaker.finish(later)
        #expect(!breaker.isTripped(containerId: "web"))
    }

    @Test("the container stays tripped until every abandoned flush returns")
    func staysTrippedUntilLastAbandonedFlushReturns() throws {
        let breaker = GuestFlushBreaker()
        // Both in flight before either timed out, as with two concurrent reads.
        let first = try #require(breaker.begin(containerId: "web"))
        let second = try #require(breaker.begin(containerId: "web"))
        #expect(breaker.abandon(first))
        #expect(breaker.abandon(second))

        breaker.finish(first)
        #expect(breaker.isTripped(containerId: "web"))
        breaker.finish(second)
        #expect(!breaker.isTripped(containerId: "web"))
    }
}

private final class DurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var longest: Duration = .zero

    func record(_ duration: Duration) {
        lock.withLock { longest = max(longest, duration) }
    }

    var value: Duration { lock.withLock { longest } }
}

private final class SizeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int64?] = []

    func record(_ size: Int64?) {
        lock.withLock { sizes.append(size) }
    }

    var values: [Int64?] { lock.withLock { sizes } }
}

private final class CountLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func record(_ count: Int) {
        lock.withLock { counts.append(count) }
    }

    var values: [Int] { lock.withLock { counts } }
}

/// A clock the test moves by hand, so trip expiry needs no waiting.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    @Sendable func now() -> ContinuousClock.Instant {
        lock.withLock { current }
    }

    func advance(by duration: Duration) {
        lock.withLock { current += duration }
    }
}

private struct FlushFailure: Error {}

/// Counts flush entries; `waitForEntry` returns once per entry (waiting for one if
/// none is left), so a gated deadline cannot fire before a flush has started.
private final class EntryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        lock.lock()
        if waiters.isEmpty {
            available += 1
            lock.unlock()
            return
        }
        let waiter = waiters.removeFirst()
        lock.unlock()
        waiter.resume()
    }

    func waitForEntry() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if available > 0 {
                available -= 1
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Stands in for an XPC await stuck forever: continuations nobody resumes, so task
/// cancellation cannot end them (unlike `Task.sleep`). `release()` resumes every
/// waiter (and any later one at once) so abandoned tasks can finish.
private final class StuckWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuations = self.continuations
        self.continuations = []
        lock.unlock()
        for continuation in continuations { continuation.resume() }
    }
}

private final class ReadResults: @unchecked Sendable {
    private let lock = NSLock()
    private var _archive: PathStat?
    private var _stat: PathStat?

    var archive: PathStat? {
        get { lock.withLock { _archive } }
        set { lock.withLock { _archive = newValue } }
    }

    var stat: PathStat? {
        get { lock.withLock { _stat } }
        set { lock.withLock { _stat = newValue } }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: ClientArchiveService.FlushOutcome?

    var outcome: ClientArchiveService.FlushOutcome? {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }
}

/// Thread-safe record of which containers the service asked to flush.
private final class FlushCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func record(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.append(id)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ids.count
    }

    func count(of id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ids.filter { $0 == id }.count
    }
}

private struct FlushFixture {
    let appSupport: URL
    let flushCalls = FlushCalls()

    init() {
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "archive-flush-test-\(UUID().uuidString)")
    }

    /// A service whose guest "write-back" rewrites `containerId`'s rootfs with the
    /// original files plus `writeback`, as a real `sync` would persist them.
    func service(writebackOf writeback: [String: String], intoContainer containerId: String) -> ClientArchiveService {
        let appSupport = appSupport
        let calls = flushCalls
        // A cap no write-back can miss, however loaded the machine.
        return ClientArchiveService(
            appSupportPath: appSupport, flushTimeout: .seconds(60),
            flushGuest: { container in
                calls.record(container.id)
                let existing = try readFiles(containerId: container.id, appSupport: appSupport)
                try writeExt4(
                    at: rootfsURL(containerId: containerId, appSupport: appSupport),
                    files: existing.merging(writeback) { _, new in new })
            })
    }

    /// A service for a wedged guest: its flush records the call and parks on `stuck`,
    /// and a flush times out only once some flush has been entered (not after a
    /// wall-clock cap). A read that flushes has therefore recorded its call before it
    /// returns, however late the flush task is scheduled. Entries and deadlines are
    /// paired by count, so this holds for reads that flush one at a time.
    func wedgedService(stuck: StuckWait, breaker: GuestFlushBreaker = GuestFlushBreaker()) -> ClientArchiveService {
        let calls = flushCalls
        let entered = EntryGate()
        return ClientArchiveService(
            appSupportPath: appSupport,
            flushDeadline: { _ in await entered.waitForEntry() },
            flushGuest: { container in
                calls.record(container.id)
                entered.enter()
                await stuck.wait()
            },
            flushBreaker: breaker)
    }

    /// A service whose flush is `flush`, capped at `flushTimeout`.
    func service(
        flushTimeout: Duration,
        breaker: GuestFlushBreaker = GuestFlushBreaker(),
        flush: @escaping @Sendable (ContainerSnapshot) async throws -> Void
    ) -> ClientArchiveService {
        ClientArchiveService(
            appSupportPath: appSupport, flushTimeout: flushTimeout, flushGuest: flush, flushBreaker: breaker)
    }

    func makeContainer(id: String, status: RuntimeStatus) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "busybox:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        return ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: img, process: proc),
            status: status, networks: [], startedDate: nil
        )
    }

    func writeRootfs(containerId: String, files: [String: String]) throws {
        try writeExt4(at: rootfsURL(containerId: containerId, appSupport: appSupport), files: files)
        try Self.record(files, containerId: containerId, appSupport: appSupport)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    // The EXT4 reader is read-only and the formatter rewrites the whole image, so the
    // fake keeps a sidecar of the files it last wrote to rebuild the image on write-back.
    private static func sidecar(containerId: String, appSupport: URL) -> URL {
        appSupport.appendingPathComponent("containers/\(containerId)/files.json")
    }

    private static func record(_ files: [String: String], containerId: String, appSupport: URL) throws {
        try JSONEncoder().encode(files).write(to: sidecar(containerId: containerId, appSupport: appSupport))
    }
}

private func rootfsURL(containerId: String, appSupport: URL) -> URL {
    let dir = appSupport.appendingPathComponent("containers/\(containerId)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("rootfs.ext4")
}

private func readFiles(containerId: String, appSupport: URL) throws -> [String: String] {
    let url = appSupport.appendingPathComponent("containers/\(containerId)/files.json")
    return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
}

private func writeExt4(at url: URL, files: [String: String]) throws {
    try? FileManager.default.removeItem(at: url)
    let formatter = try EXT4.Formatter(FilePath(url.path))
    for (path, contents) in files {
        let stream = InputStream(data: Data(contents.utf8))
        stream.open()
        try formatter.create(
            path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
    }
    try formatter.close()
}
