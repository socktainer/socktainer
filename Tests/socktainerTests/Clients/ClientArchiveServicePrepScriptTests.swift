import ContainerResource
import Foundation
import Testing

@testable import socktainer

@Suite("ClientArchiveService guest preparation script", .serialized)
struct ClientArchiveServicePrepScriptTests {

    /// Linux caps a single argv string at 128 KiB (MAX_ARG_STRLEN).
    private static let maxArgStringLength = 128 * 1024

    private let service = ClientArchiveService(appSupportPath: FileManager.default.temporaryDirectory)

    /// A tree like a vendored action or node_modules checkout: many nested
    /// directories, one file in each.
    private func entries(directories count: Int) -> [ClientArchiveService.ArchiveEntryPlan] {
        (0..<count).map { index in
            let relative = "pkg-\(index % 40)/sub-\(index / 40)/nested-directory-name/file-\(index).txt"
            return ClientArchiveService.ArchiveEntryPlan(
                relativePath: relative,
                guestPath: "/var/run/act/actions/some-org-some-repo-actions-checkout@stable/\(relative)",
                kind: .file,
                mode: 0o644
            )
        }
    }

    private func runningContainer() throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: "rv-archive-prep",
            ip: "192.168.65.2",
            network: "default",
            labels: [:],
            status: .running
        )
    }

    @Test("the script for a large archive is longer than one argv string may be")
    func largeArchiveScriptExceedsArgvLimit() {
        let script = service.buildPreparationScript(
            entries: entries(directories: 2000),
            noOverwriteDirNonDir: false
        )

        #expect(
            script.utf8.count > Self.maxArgStringLength,
            "the premise of sending the script over stdin: it outgrows a single argv string")
    }

    @Test("a large archive launches `sh -s <dest>` with the script on stdin")
    func largeArchiveLaunchKeepsScriptOutOfArgv() throws {
        let entries = entries(directories: 2000)
        let script = service.buildPreparationScript(entries: entries, noOverwriteDirNonDir: false)

        let launch = service.makeGuestPreparationLaunch(
            container: try runningContainer(),
            destinationPath: "/var/run/act/actions",
            entries: entries,
            noOverwriteDirNonDir: false
        )

        #expect(launch.configuration.executable == "/bin/sh")
        #expect(launch.configuration.arguments == ["-s", "/var/run/act/actions"])
        #expect(launch.configuration.terminal == false)
        #expect(launch.configuration.user == .id(uid: 0, gid: 0))
        #expect(launch.stdin == Data(script.utf8))
        for argument in [launch.configuration.executable] + launch.configuration.arguments {
            #expect(
                argument.utf8.count < Self.maxArgStringLength,
                "every argv string must stay under MAX_ARG_STRLEN or exec fails in the guest")
        }
    }

    @Test("a small archive is launched the same way")
    func smallArchiveLaunchAlsoUsesStdin() throws {
        let script = service.buildPreparationScript(entries: [], noOverwriteDirNonDir: true)

        let launch = service.makeGuestPreparationLaunch(
            container: try runningContainer(),
            destinationPath: "/tmp",
            entries: [],
            noOverwriteDirNonDir: true
        )

        #expect(launch.configuration.executable == "/bin/sh")
        #expect(launch.configuration.arguments == ["-s", "/tmp"])
        #expect(String(decoding: launch.stdin, as: UTF8.self) == script)
    }

    /// Hang guard for the feedStdin tests below. It never bounds how long a
    /// passing run may take; it only turns a deadlock into a failure.
    private static let watchdog: DispatchTimeInterval = .seconds(60)

    /// Read exactly `count` bytes (blocking) on a GCD thread, then signal the
    /// returned semaphore, so the read finishes whether or not the write end
    /// is ever closed and the caller can wait for it with the watchdog.
    private func readExactly(
        _ count: Int, from reader: FileHandle, into state: ReaderState
    ) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var received = Data()
            while received.count < count,
                let chunk = try? reader.read(upToCount: min(64 * 1024, count - received.count)),
                !chunk.isEmpty
            {
                received.append(chunk)
            }
            state.set(received: received)
            done.signal()
        }
        return done
    }

    /// Without blocking: read(2) returns 0 at EOF but -1/EAGAIN while the
    /// write end is still open.
    private func readEndSeesEOF(_ reader: FileHandle) -> (Bool, String) {
        _ = fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK)
        var byte: UInt8 = 0
        let n = Darwin.read(reader.fileDescriptor, &byte, 1)
        return (n == 0, "read returned \(n), errno \(errno)")
    }

    /// After the write has completed: the pipe holds exactly `payload` and the
    /// write end is closed. Never blocks, even if the write end is left open.
    private func expectPayloadThenEOF(_ payload: Data, from reader: FileHandle) throws {
        _ = fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: payload.count + 1)
        let n = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
        #expect(n == payload.count && Data(buffer.prefix(max(n, 0))) == payload, "read returned \(n)")
        let (eof, detail) = readEndSeesEOF(reader)
        #expect(eof, "stdin write end must be closed after the payload so the reader sees EOF (\(detail))")
    }

    /// Not async: the waits below block this thread on semaphores.
    @Test("a payload larger than the pipe buffer reaches the reader followed by EOF")
    func feedStdinDeliversLargePayloadAndEOF() throws {
        let pipes = try #require(StdioPipes.make([.stdin]))
        let stdin = try #require(pipes.stdin)
        let payload = Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        let reader = stdin.read
        defer { try? reader.close() }
        let readerState = ReaderState()
        let readerDone = readExactly(payload.count, from: reader, into: readerState)

        let writeResult = WriteResult()
        let completed = DispatchSemaphore(value: 0)
        ClientArchiveService.feedStdin(writer: stdin.write, data: payload) { error in
            writeResult.set(error)
            completed.signal()
        }
        let writeFinished = completed.wait(timeout: .now() + Self.watchdog) == .success
        let readerFinished = readerDone.wait(timeout: .now() + Self.watchdog) == .success

        try #require(writeFinished, "feedStdin must report completion once the payload is read")
        try #require(readerFinished, "the reader must receive the whole payload")
        #expect(writeResult.error == nil)
        #expect(readerState.received.count == payload.count)
        #expect(readerState.received == payload)

        // The write has finished, so `sh -s` must now see EOF.
        let (eof, detail) = readEndSeesEOF(reader)
        #expect(eof, "stdin write end must be closed after the payload so the reader sees EOF (\(detail))")
    }

    /// Not async: the waits below block this thread on semaphores.
    @Test("feeding a payload nobody reads yet returns to the caller before it is consumed")
    func feedStdinDoesNotBlockTheCaller() throws {
        let pipes = try #require(StdioPipes.make([.stdin]))
        let stdin = try #require(pipes.stdin)
        let reader = stdin.read
        defer { try? reader.close() }
        // Well past the pipe buffer, so the write cannot complete until read.
        let payload = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })

        // The reader starts consuming only once feedStdin has returned. If
        // feedStdin wrote inline it could never return before this gate opens,
        // because nothing else drains the pipe; the watchdog then lets the
        // reader proceed so the test fails instead of hanging.
        let returned = DispatchSemaphore(value: 0)
        let readerState = ReaderState()
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let gateOpened = returned.wait(timeout: .now() + Self.watchdog) == .success
            var received = Data()
            while received.count < payload.count,
                let chunk = try? reader.read(upToCount: min(64 * 1024, payload.count - received.count)),
                !chunk.isEmpty
            {
                received.append(chunk)
            }
            readerState.set(gateOpened: gateOpened, received: received)
            readerDone.signal()
        }

        let writeResult = WriteResult()
        let completed = DispatchSemaphore(value: 0)
        ClientArchiveService.feedStdin(writer: stdin.write, data: payload) { error in
            writeResult.set(error)
            completed.signal()
        }
        // Nobody has read yet, so the write cannot have finished.
        let finishedBeforeRead = writeResult.finished
        returned.signal()

        let readerFinished = readerDone.wait(timeout: .now() + Self.watchdog) == .success
        let writeFinished = completed.wait(timeout: .now() + Self.watchdog) == .success

        #expect(readerState.gateOpened, "feedStdin must return before the payload is read")
        #expect(!finishedBeforeRead, "the write cannot complete before the payload is read")
        #expect(readerFinished && writeFinished, "the write must finish once the payload is read")
        #expect(readerState.received == payload)
        #expect(writeResult.finished && writeResult.error == nil)
        let (eof, detail) = readEndSeesEOF(reader)
        #expect(eof, "stdin write end must be closed after the payload so the reader sees EOF (\(detail))")
    }

    @Test("the write and the close run on the given dispatch queue, not on a Swift task")
    func feedStdinRunsOnTheGivenQueue() throws {
        let pipes = try #require(StdioPipes.make([.stdin]))
        let stdin = try #require(pipes.stdin)
        let reader = stdin.read
        defer { try? reader.close() }
        let payload = Data("mkdir -p x\n".utf8)

        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "rv-feed-stdin-test")
        queue.setSpecific(key: key, value: "rv-feed-stdin-test")

        let ranOn = WriteResult()
        let completed = DispatchSemaphore(value: 0)
        ClientArchiveService.feedStdin(writer: stdin.write, data: payload, queue: queue) { error in
            ranOn.set(error, label: DispatchQueue.getSpecific(key: key))
            completed.signal()
        }

        let finished = completed.wait(timeout: .now() + Self.watchdog) == .success
        #expect(finished, "the queued write must complete")
        #expect(ranOn.label == "rv-feed-stdin-test", "the write must run on the queue passed to feedStdin")
        #expect(ranOn.error == nil)
        try expectPayloadThenEOF(payload, from: reader)
    }

    /// Not async: the waits below block this thread on semaphores.
    @Test("stuck stdin writes on the default queue do not hold up another upload's write")
    func feedStdinDefaultQueueIsConcurrent() throws {
        // A few writes blocked on pipes nobody reads, like guests that stopped
        // reading their preparation script. Kept small: GCD grows its pool for
        // threads blocked in syscalls, so this does not depend on core count.
        let stuckCount = 4
        let payload = Data(repeating: 0x41, count: 1024 * 1024)
        var stuckReaders: [FileHandle] = []
        let stuck = DispatchGroup()
        defer {
            // Release the blocked writes (EPIPE) whatever the outcome.
            for reader in stuckReaders { try? reader.close() }
            _ = stuck.wait(timeout: .now() + Self.watchdog)
        }
        // feedStdin is called off this thread, and only its return is awaited
        // (with the watchdog), so a feedStdin that wrote inline fails the test
        // instead of blocking it before the readers below can be closed.
        let queued = DispatchSemaphore(value: 0)
        for _ in 0..<stuckCount {
            let pipes = try #require(StdioPipes.make([.stdin]))
            let stdin = try #require(pipes.stdin)
            let writer = stdin.write
            stuckReaders.append(stdin.read)
            stuck.enter()
            DispatchQueue.global().async {
                ClientArchiveService.feedStdin(writer: writer, data: payload) { _ in stuck.leave() }
                queued.signal()
            }
        }
        let queuedDeadline = DispatchTime.now() + Self.watchdog
        var allQueued = true
        for _ in 0..<stuckCount where queued.wait(timeout: queuedDeadline) != .success {
            allQueued = false
        }
        try #require(allQueued, "feedStdin must return without waiting for the write")

        // Another upload whose guest does read must still get its script.
        let pipes = try #require(StdioPipes.make([.stdin]))
        let stdin = try #require(pipes.stdin)
        let reader = stdin.read
        defer { try? reader.close() }
        let small = Data("mkdir -p y\n".utf8)
        let completed = DispatchSemaphore(value: 0)
        let result = WriteResult()
        ClientArchiveService.feedStdin(writer: stdin.write, data: small) { error in
            result.set(error)
            completed.signal()
        }
        let finished = completed.wait(timeout: .now() + Self.watchdog) == .success

        #expect(finished, "a write must not queue behind writes stuck on other pipes")
        #expect(result.error == nil)
        if finished {
            try expectPayloadThenEOF(small, from: reader)
        }
    }

    /// Not async: the waits below block this thread on semaphores.
    @Test("a reader that goes away early makes the write fail with EPIPE, not SIGPIPE")
    func feedStdinSurvivesEarlyReaderExit() throws {
        let pipes = try #require(StdioPipes.make([.stdin]))
        let stdin = try #require(pipes.stdin)
        // Far larger than the pipe buffer, so the write is still blocked when
        // the reader goes away.
        let payload = Data(repeating: 0x41, count: 1024 * 1024)
        let writer = stdin.write
        let reader = stdin.read

        // feedStdin is called off this thread and only its return is awaited
        // (with the watchdog): a feedStdin that wrote inline would block here
        // forever, because nothing reads until the reader is closed below.
        let writeResult = WriteResult()
        let completed = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ClientArchiveService.feedStdin(writer: writer, data: payload) { error in
                writeResult.set(error)
                completed.signal()
            }
            returned.signal()
        }
        let returnedInTime = returned.wait(timeout: .now() + Self.watchdog) == .success
        #expect(returnedInTime, "feedStdin must return without waiting for the write")

        // Only checked if feedStdin returned in time: nothing reads, so the
        // write is still blocked and the write end is still open here. After a
        // timeout the fd may already be closed and its number reused.
        if returnedInTime {
            #expect(
                fcntl(writer.fileDescriptor, F_GETNOSIGPIPE) == 1,
                "SIGPIPE must be suppressed on the stdin write end before the write starts")
        }

        // Like `sh -s` exiting 40 before consuming the script. Without
        // F_SETNOSIGPIPE the blocked write raises SIGPIPE and kills this process.
        // Closed unconditionally: it is also what unblocks an inline write.
        try reader.close()

        let finished = completed.wait(timeout: .now() + Self.watchdog) == .success
        try #require(finished, "the write must complete once the reader is gone")
        guard let error = writeResult.error else {
            Issue.record("writing to a pipe whose reader is gone must fail")
            return
        }
        let nsError = error as NSError
        let posixCode =
            nsError.domain == NSPOSIXErrorDomain
            ? nsError.code
            : (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        #expect(posixCode == Int(EPIPE), "unexpected error: \(nsError)")
    }
}

/// The error a `feedStdin` completion reported, read after it has run.
private final class WriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    private var storedLabel: String?
    private var done = false

    func set(_ error: Error?, label: String? = nil) {
        lock.withLock {
            stored = error
            storedLabel = label
            done = true
        }
    }

    var finished: Bool {
        lock.withLock { done }
    }

    var error: Error? {
        lock.withLock { stored }
    }

    /// The test queue's specific value seen by the completion, if any.
    var label: String? {
        lock.withLock { storedLabel }
    }
}

/// What the gated reader saw, read after it has signalled.
private final class ReaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var data = Data()

    func set(gateOpened: Bool = true, received: Data) {
        lock.withLock {
            opened = gateOpened
            data = received
        }
    }

    var gateOpened: Bool {
        lock.withLock { opened }
    }

    var received: Data {
        lock.withLock { data }
    }
}
