import Foundation

/// The readers served share one file handle each, so a reader goes to one caller at a time.
final class FileReaderCache<Reader>: @unchecked Sendable {
    private let capacity: Int
    private let idleTimeout: Duration
    private let now: () -> ContinuousClock.Instant
    private let scheduleAfter: (Duration, @escaping @Sendable () -> Void) -> Void
    private let open: (String) throws -> Reader
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var recentFirst: [String] = []
    private var idleReleasePending = false

    init(
        capacity: Int,
        idleTimeout: Duration,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        scheduleAfter: @escaping (Duration, @escaping @Sendable () -> Void) -> Void = { delay, work in
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
        },
        open: @escaping (String) throws -> Reader
    ) {
        self.capacity = capacity
        self.idleTimeout = idleTimeout
        self.now = now
        self.scheduleAfter = scheduleAfter
        self.open = open
    }

    func withReader<Result>(at path: String, _ body: (Reader) throws -> Result) throws -> Result {
        lock.withLock { dropEntriesOfChangedFiles() }
        let identity = try FileIdentity(path: path)
        let entry = checkOut(path, identity: identity)
        defer {
            checkIn(entry)
            scheduleIdleRelease()
        }
        var openFailed = false
        do {
            return try entry.withReader(
                opening: {
                    do {
                        return try open(path)
                    } catch {
                        openFailed = true
                        throw error
                    }
                }, body)
        } catch {
            if openFailed { forget(entry, at: path) }
            throw error
        }
    }

    private func forget(_ entry: Entry, at path: String) {
        lock.withLock {
            if entries[path] === entry { drop(path) }
        }
    }

    func releaseVanishedFiles() {
        lock.withLock { dropEntriesOfChangedFiles() }
    }

    func releaseIdleReaders() {
        lock.withLock { dropIdleEntries() }
    }

    private func checkOut(_ path: String, identity: FileIdentity) -> Entry {
        lock.withLock {
            recentFirst.removeAll { $0 == path }
            recentFirst.insert(path, at: 0)
            let entry: Entry
            if let cached = entries[path], cached.identity == identity {
                entry = cached
            } else {
                entry = Entry(identity: identity, lastUsed: now())
                entries[path] = entry
                for evicted in recentFirst.dropFirst(capacity) where (entries[evicted]?.users ?? 0) == 0 {
                    drop(evicted)
                }
            }
            entry.users += 1
            return entry
        }
    }

    private func checkIn(_ entry: Entry) {
        lock.withLock {
            entry.users -= 1
            entry.lastUsed = now()
        }
    }

    private func scheduleIdleRelease() {
        let firstPending = lock.withLock {
            guard !idleReleasePending, !entries.isEmpty else { return false }
            idleReleasePending = true
            return true
        }
        if firstPending { armIdleRelease(after: idleTimeout) }
    }

    private func armIdleRelease(after delay: Duration) {
        scheduleAfter(delay) { [weak self] in self?.runIdleRelease() }
    }

    private func runIdleRelease() {
        let nextDelay: Duration? = lock.withLock {
            dropIdleEntries()
            idleReleasePending = !entries.isEmpty
            return idleReleasePending ? delayUntilNextExpiry() : nil
        }
        if let nextDelay { armIdleRelease(after: nextDelay) }
    }

    private func delayUntilNextExpiry() -> Duration {
        let current = now()
        let expiries = entries.values.map { $0.users == 0 ? $0.lastUsed + idleTimeout : current + idleTimeout }
        return (expiries.min() ?? current + idleTimeout) - current
    }

    private func dropIdleEntries() {
        dropEntriesOfChangedFiles()
        let current = now()
        for (path, entry) in entries where entry.users == 0 && current - entry.lastUsed >= idleTimeout {
            drop(path)
        }
    }

    private func dropEntriesOfChangedFiles() {
        for (path, entry) in entries where (try? FileIdentity(path: path)) != entry.identity {
            drop(path)
        }
    }

    private func drop(_ path: String) {
        entries[path] = nil
        recentFirst.removeAll { $0 == path }
    }

    private final class Entry: @unchecked Sendable {
        let identity: FileIdentity
        var users = 0
        var lastUsed: ContinuousClock.Instant
        private let inUse = NSLock()
        private var reader: Reader?

        init(identity: FileIdentity, lastUsed: ContinuousClock.Instant) {
            self.identity = identity
            self.lastUsed = lastUsed
        }

        func withReader<Result>(opening open: () throws -> Reader, _ body: (Reader) throws -> Result) throws -> Result {
            try inUse.withLock {
                let opened = try reader ?? open()
                reader = opened
                return try body(opened)
            }
        }
    }
}

private struct FileIdentity: Equatable {
    let fileNumber: UInt64
    let size: UInt64
    let modification: Date

    init(path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modification = attributes[.modificationDate] as? Date ?? .distantPast
    }
}
