import ContainerResource
import Darwin
import Foundation

/// Durable Docker-facing metadata that Apple Container cannot represent natively.
///
/// Apple container identifiers are immutable and its 1.2.1 API has no rename operation.
/// Published ports also have to be owned by Glass Dock on macOS versions where the
/// Apple runtime helper loses local-network authorization. Keeping both properties in
/// one atomically-written registry makes name/port mutations linearizable and allows
/// daemon restart reconciliation without changing the underlying container or volumes.
actor DockerContainerMetadataStore {
    static let shared = DockerContainerMetadataStore()

    struct Entry: Codable, Sendable {
        var name: String
        var publishedPorts: [PublishPort]
        /// Non-nil only across the native-create uncertainty window. Keeping the
        /// durable alias during a short list absence lets a restarted daemon
        /// converge an Apple create that completed after the HTTP request died.
        var pendingSince: Date?
        /// First confirmed absence for a committed native object. Stable entries
        /// require a grace period so a transient Apple restart/partial list cannot
        /// erase Docker names or desired port mappings.
        var missingSince: Date?
        /// Docker's `--rm` intent must outlive the daemon because Apple may reap
        /// the native object before a restarted observer can inspect it.
        var autoRemove: Bool?

        init(
            name: String,
            publishedPorts: [PublishPort],
            pendingSince: Date? = nil,
            missingSince: Date? = nil,
            autoRemove: Bool = false
        ) {
            self.name = name
            self.publishedPorts = publishedPorts
            self.pendingSince = pendingSince
            self.missingSince = missingSince
            self.autoRemove = autoRemove
        }
    }

    struct NameReservation: Sendable {
        fileprivate let id: UUID
        let name: String
    }

    enum StoreError: Error, Equatable {
        case nameConflict(String)
        case invalidName(String)
        case sameName(String)
        case lockUnavailable
    }

    private var entries: [String: Entry] = [:]
    private var reservations: [String: UUID] = [:]
    private var fileURL: URL?
    private var lockFD: Int32 = -1

    deinit {
        if lockFD >= 0 { _ = close(lockFD) }
    }

    func configure(
        storageDirectory: URL,
        enforceExclusiveAccess: Bool = false
    ) throws {
        let directory = storageDirectory.appendingPathComponent("glassdock", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if enforceExclusiveAccess {
            let lockURL = directory.appendingPathComponent("docker-containers.lock")
            let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw StoreError.lockUnavailable }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                _ = close(fd)
                throw StoreError.lockUnavailable
            }
            if lockFD >= 0 { _ = close(lockFD) }
            lockFD = fd
        }
        fileURL = directory.appendingPathComponent("docker-containers.json")
        entries = [:]
        reservations = [:]
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))
    }

    func adopt(nativeID: String, name: String, publishedPorts: [PublishPort]) throws {
        guard entries[nativeID] == nil else { return }
        let adoptedName = uniqueAdoptionName(requested: name)
        var next = entries
        next[nativeID] = Entry(name: adoptedName, publishedPorts: publishedPorts)
        try commit(next)
    }

    /// Transactional metadata replacement used by migration and focused tests.
    /// New container creation must use reserve/commit so name ownership is serialized.
    func set(nativeID: String, name: String, publishedPorts: [PublishPort]) throws {
        var next = entries
        next[nativeID] = Entry(name: Self.normalized(name), publishedPorts: publishedPorts)
        try commit(next)
    }

    func reserve(name requestedName: String, existingNativeIDs: Set<String>) throws -> NameReservation {
        let name = Self.normalized(requestedName)
        guard Self.isValid(name) else { throw StoreError.invalidName(requestedName) }
        guard reservations[name] == nil else { throw StoreError.nameConflict(name) }
        guard !entries.values.contains(where: { $0.name == name }) else {
            throw StoreError.nameConflict(name)
        }
        for nativeID in existingNativeIDs where (entries[nativeID]?.name ?? nativeID) == name {
            throw StoreError.nameConflict(name)
        }
        let reservation = NameReservation(id: UUID(), name: name)
        reservations[name] = reservation.id
        return reservation
    }

    /// Durably publishes the name and ports before the native create begins.
    /// A crash after this point is reconciled by removing the entry when no native
    /// container with `nativeID` exists; a crash before it cannot expose a name.
    func commit(
        reservation: NameReservation,
        nativeID: String,
        publishedPorts: [PublishPort],
        autoRemove: Bool = false
    ) throws {
        guard reservations[reservation.name] == reservation.id else {
            throw StoreError.nameConflict(reservation.name)
        }
        var next = entries
        next[nativeID] = Entry(
            name: reservation.name,
            publishedPorts: publishedPorts,
            pendingSince: Date(),
            autoRemove: autoRemove
        )
        try persist(next)
        entries = next
        reservations.removeValue(forKey: reservation.name)
    }

    func cancel(reservation: NameReservation) {
        guard reservations[reservation.name] == reservation.id else { return }
        reservations.removeValue(forKey: reservation.name)
    }

    func rename(
        nativeID: String,
        to requestedName: String,
        existingNativeIDs: Set<String>,
        onCommit: (@Sendable (_ oldName: String, _ newName: String) -> Void)? = nil
    ) throws -> (old: String, new: String) {
        let newName = Self.normalized(requestedName)
        guard Self.isValid(newName) else { throw StoreError.invalidName(requestedName) }
        let oldName = entries[nativeID]?.name ?? nativeID
        if oldName == newName { throw StoreError.sameName(newName) }
        if reservations[newName] != nil { throw StoreError.nameConflict(newName) }

        if entries.contains(where: { $0.key != nativeID && $0.value.name == newName }) {
            throw StoreError.nameConflict(newName)
        }
        for id in existingNativeIDs where id != nativeID {
            let effective = entries[id]?.name ?? id
            if effective == newName { throw StoreError.nameConflict(newName) }
        }
        var renamed =
            entries[nativeID]
            ?? Entry(name: oldName, publishedPorts: [])
        renamed.name = newName
        var next = entries
        next[nativeID] = renamed
        try commit(next)
        // Keep dependent in-memory indexes (notably DNS aliases) inside the
        // same actor-serialized mutation boundary. Running this after the
        // durable commit but before another rename can enter prevents an older
        // request from publishing a stale alias after a newer rename.
        onCommit?(oldName, newName)
        return (oldName, newName)
    }

    func entry(nativeID: String) -> Entry? { entries[nativeID] }
    func name(nativeID: String) -> String { entries[nativeID]?.name ?? nativeID }
    func ports(nativeID: String, fallback: [PublishPort] = []) -> [PublishPort] {
        entries[nativeID]?.publishedPorts ?? fallback
    }

    func nativeID(named requestedName: String, existingNativeIDs: Set<String>) throws -> String? {
        let name = Self.normalized(requestedName)
        let matches = existingNativeIDs.filter { (entries[$0]?.name ?? $0) == name }
        if matches.count > 1 { throw StoreError.nameConflict(name) }
        return matches.first
    }

    func remove(nativeID: String) throws {
        guard entries[nativeID] != nil else { return }
        var next = entries
        next.removeValue(forKey: nativeID)
        try commit(next)
    }

    func markCreated(nativeID: String) throws {
        guard var entry = entries[nativeID], entry.pendingSince != nil else { return }
        entry.pendingSince = nil
        var next = entries
        next[nativeID] = entry
        try commit(next)
    }

    func reconcile(
        existingNativeIDs: Set<String>,
        now: Date = Date()
    ) throws {
        var next = entries
        var changed = false
        for (id, var entry) in entries {
            if existingNativeIDs.contains(id) {
                if entry.pendingSince != nil || entry.missingSince != nil {
                    entry.pendingSince = nil
                    entry.missingSince = nil
                    next[id] = entry
                    changed = true
                }
            } else if let pendingSince = entry.pendingSince {
                if now.timeIntervalSince(pendingSince) >= 10 * 60 {
                    next.removeValue(forKey: id)
                    changed = true
                }
            } else if let missingSince = entry.missingSince {
                if now.timeIntervalSince(missingSince) >= 10 * 60 {
                    next.removeValue(forKey: id)
                    changed = true
                }
            } else {
                entry.missingSince = now
                next[id] = entry
                changed = true
            }
        }
        guard changed else { return }
        try commit(next)
    }

    static func normalized(_ name: String) -> String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        return name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    private func commit(_ next: [String: Entry]) throws {
        try persist(next)
        entries = next
    }

    /// Legacy Apple containers have an immutable native ID that historically
    /// doubled as their Docker name. If that ID now collides with a managed
    /// logical alias, preserve the existing canonical owner and give the legacy
    /// object a deterministic visible alias; its stable Docker ID remains valid.
    private func uniqueAdoptionName(requested: String) -> String {
        let normalized = Self.normalized(requested)
        func available(_ candidate: String) -> Bool {
            reservations[candidate] == nil
                && !entries.values.contains(where: { $0.name == candidate })
        }
        if Self.isValid(normalized), available(normalized) { return normalized }

        var stem = normalized.replacingOccurrences(
            of: #"[^a-zA-Z0-9_.-]"#,
            with: "-",
            options: .regularExpression
        )
        if stem.range(of: #"^[a-zA-Z0-9]"#, options: .regularExpression) == nil {
            stem = "container-\(stem)"
        }
        var sequence = 1
        while true {
            let suffix = sequence == 1 ? "-native" : "-native-\(sequence)"
            let maximumStemLength = max(1, 255 - suffix.count)
            let candidate = String(stem.prefix(maximumStemLength)) + suffix
            if available(candidate) { return candidate }
            sequence += 1
        }
    }

    private func persist(_ next: [String: Entry]) throws {
        // Route-level unit tests use the store in memory without booting the full
        // application. Production always calls configure() before routes register.
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(next)
        try data.write(to: fileURL, options: [.atomic])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.synchronize()
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        try handle.close()
        let directoryFD = open(fileURL.deletingLastPathComponent().path, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            _ = close(directoryFD)
        }
    }
}
