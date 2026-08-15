import Darwin
import Foundation

struct ImageReferenceConstraintAssignment: Sendable {
    let reference: String
    let rootDigest: String
    let constraint: RunnableImageIdentityConstraint
}

struct ImageReferenceConstraintTransaction: Sendable {
    fileprivate let id: UUID
    fileprivate let references: Set<String>
}

/// Crash-recoverable persistence for the exact OCI selector behind a Docker tag.
///
/// Apple's reference store can only persist `tag -> root index`. Docker also
/// permits tagging a nested index, manifest, or config ID. Storing that selector
/// beside the Apple reference preserves the round trip without copying image
/// layers into a derived root. A pending journal entry is written after the XPC
/// operation has produced its new root but before the canonical tag commit. On
/// restart, the root currently owning the tag selects the old or new side of the
/// journal, so neither crash window can publish an unrelated platform variant.
actor ImageReferenceConstraintStore {
    struct Entry: Codable, Equatable, Sendable {
        let rootDigest: String
        let constraint: RunnableImageIdentityConstraint
    }

    private struct Pending: Codable, Sendable {
        let transactionID: UUID
        let oldEntry: Entry?
        let newRootDigest: String?
        let newEntry: Entry?
    }

    private struct State: Codable, Sendable {
        static let currentVersion = 1

        var version = currentVersion
        var entries: [String: Entry] = [:]
        var pending: [String: Pending] = [:]
    }

    private static let maximumStateBytes = 4 * 1024 * 1024
    private static let maximumEntries = 100_000
    private let directory: URL
    private let stateURL: URL

    init(appSupportURL: URL) {
        directory = appSupportURL.appendingPathComponent(
            "glassdock",
            isDirectory: true
        )
        stateURL = directory.appendingPathComponent(
            "image-reference-constraints.json",
            isDirectory: false
        )
    }

    func effectiveEntries(
        currentRootByReference: [String: String]
    ) throws -> [String: Entry] {
        let state = try load()
        return Self.effectiveEntries(
            in: state,
            currentRootByReference: currentRootByReference
        )
    }

    /// Finalizes journals left by a killed daemon before beginning another
    /// image mutation. The Apple root is the commit witness.
    func reconcile(
        currentRootByReference: [String: String]
    ) throws {
        var state = try load()
        guard !state.pending.isEmpty else { return }
        state.entries = Self.effectiveEntries(
            in: state,
            currentRootByReference: currentRootByReference
        )
        state.pending.removeAll()
        try save(state)
    }

    func prepare(
        _ assignments: [ImageReferenceConstraintAssignment]
    ) throws -> ImageReferenceConstraintTransaction {
        var state = try load()
        let id = UUID()
        var references: Set<String> = []
        for assignment in assignments {
            references.insert(assignment.reference)
            let newEntry = Self.persistedEntry(for: assignment)
            state.pending[assignment.reference] = Pending(
                transactionID: id,
                oldEntry: state.entries[assignment.reference],
                newRootDigest: Self.canonicalDigest(
                    assignment.rootDigest
                ),
                newEntry: newEntry
            )
        }
        try validateSize(state)
        try save(state)
        return ImageReferenceConstraintTransaction(
            id: id,
            references: references
        )
    }

    func commit(_ transaction: ImageReferenceConstraintTransaction) throws {
        var state = try load()
        for reference in transaction.references {
            guard
                let pending = state.pending[reference],
                pending.transactionID == transaction.id
            else {
                continue
            }
            if let newEntry = pending.newEntry {
                state.entries[reference] = newEntry
            } else {
                state.entries.removeValue(forKey: reference)
            }
            state.pending.removeValue(forKey: reference)
        }
        try save(state)
    }

    private static func persistedEntry(
        for assignment: ImageReferenceConstraintAssignment
    ) -> Entry? {
        guard assignment.constraint != .unconstrained else { return nil }
        return Entry(
            rootDigest: canonicalDigest(assignment.rootDigest),
            constraint: assignment.constraint
        )
    }

    private static func effectiveEntries(
        in state: State,
        currentRootByReference: [String: String]
    ) -> [String: Entry] {
        var effective = state.entries
        for (reference, pending) in state.pending {
            let currentRoot = currentRootByReference[reference].map(
                canonicalDigest
            )
            if (pending.newRootDigest ?? pending.newEntry?.rootDigest)
                == currentRoot
            {
                if let newEntry = pending.newEntry {
                    effective[reference] = newEntry
                } else {
                    effective.removeValue(forKey: reference)
                }
            } else if let oldEntry = pending.oldEntry,
                oldEntry.rootDigest == currentRoot
            {
                effective[reference] = oldEntry
            } else {
                effective.removeValue(forKey: reference)
            }
        }
        return effective.filter { reference, entry in
            currentRootByReference[reference].map(canonicalDigest)
                == entry.rootDigest
        }
    }

    private func load() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return State()
        }
        let data = try BoundedFileReader.read(
            relativePath: stateURL.lastPathComponent,
            under: directory,
            maxBytes: Self.maximumStateBytes
        )
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.version == State.currentVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try validateSize(state)
        return state
    }

    private func save(_ state: State) throws {
        try validateSize(state)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumStateBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
        try Self.synchronize(stateURL)
        try Self.synchronize(directory)
    }

    private func validateSize(_ state: State) throws {
        guard
            state.entries.count <= Self.maximumEntries,
            state.pending.count <= Self.maximumEntries
        else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                | (url.hasDirectoryPath ? O_DIRECTORY : 0)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func canonicalDigest(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? digest : "sha256:\(digest)"
    }
}
