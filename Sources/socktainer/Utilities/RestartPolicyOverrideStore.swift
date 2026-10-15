import Foundation
import Logging

/// Durable lifecycle state for a managed container instance across daemon restarts.
struct RestartLifecycleRecord: Codable, Sendable, Equatable {
    /// An in-flight lifecycle transition recorded before the runtime call completes.
    enum PendingAction: String, Codable, Sendable {
        case start
        case stop
        case remove
    }

    var hasStarted = false
    var manuallyStopped = false
    var pendingAction: PendingAction?
    /// Missing in older lifecycle records; absence is not evidence of zero retries.
    var restartAttempts: Int? = 0
    /// The instance's real final exit code from its last completed run, committed
    /// when that run's exit was observed. Missing means unknown, not zero; the
    /// wait-failure sentinel (-1) likewise means unknown. Cleared when a new run starts.
    var lastExitCode: Int32? = nil
}

/// Restart policies are baked into container labels at create time and Apple
/// Container's configuration is immutable afterwards — `docker update` therefore
/// records an override here, consulted before the label. Persisted alongside
/// lifecycle evidence so restart policies and manual stop intent survive daemon restarts.
///
/// Keyed by the instance-unique Docker hex id (name + creation date), never the
/// reusable native name: a recreated container gets a fresh key, so a stale
/// entry can never apply to the wrong instance.
actor RestartPolicyOverrideStore {
    static let shared = RestartPolicyOverrideStore()

    private struct Document: Codable {
        var schemaVersion = 1
        var overrides: [String: RestartPolicy] = [:]
        var lifecycles: [String: RestartLifecycleRecord] = [:]

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case overrides
            case lifecycles
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.schemaVersion) else {
                overrides = try decoder.singleValueContainer().decode([String: RestartPolicy].self)
                return
            }
            let version = try container.decode(Int.self, forKey: .schemaVersion)
            guard version == 1 else { throw PersistenceError.unsupportedSchemaVersion(version) }
            overrides = try container.decode([String: RestartPolicy].self, forKey: .overrides)
            lifecycles = try container.decode([String: RestartLifecycleRecord].self, forKey: .lifecycles)
        }
    }

    /// Errors raised when loading or validating persisted restart state.
    enum PersistenceError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
        case invalidRestartAttempts
    }

    private var document = Document()
    private var fileURL: URL?
    private var configurationError: (any Error)?
    private let log = Logger(label: "socktainer.restart-policy-overrides")

    /// Loads persisted policy overrides and container lifecycle records from `storageDirectory`.
    func configure(storageDirectory: URL) throws {
        let url = storageDirectory.appendingPathComponent("socktainer-restart-policy-overrides.json")
        fileURL = url
        do {
            let loaded: Document
            do {
                loaded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                loaded = Document()
            }
            guard loaded.lifecycles.values.allSatisfy({ (0..<Int.max).contains($0.restartAttempts ?? 0) }) else {
                throw PersistenceError.invalidRestartAttempts
            }
            document = loaded
            configurationError = nil
        } catch {
            configurationError = error
            throw error
        }
    }

    /// Persists a restart policy override for `id`, logging if the disk write fails.
    func set(id: String, policy: RestartPolicy) {
        do {
            try mutate { $0.overrides[id] = policy }
        } catch {
            log.error("could not persist restart-policy override for \(id): \(error)")
        }
    }

    /// Returns the persisted restart policy override for `id`, if any.
    func get(id: String) -> RestartPolicy? {
        document.overrides[id]
    }

    /// Returns the persisted lifecycle record for `id`, if any.
    func lifecycle(id: String) -> RestartLifecycleRecord? {
        document.lifecycles[id]
    }

    /// Records that a start was requested for `id` before invoking the runtime.
    /// The retry budget is evidence of past runs and survives the intent: only a
    /// successful start (`recordStarted` / `recordRestarted`) begins the new
    /// lifecycle that resets it, so a start that fails — or a daemon that dies
    /// mid-start — cannot spend or erase the budget the previous runs earned.
    func recordStartIntent(id: String) throws {
        try mutate { document in
            document.lifecycles[id, default: RestartLifecycleRecord()].pendingAction = .start
        }
    }

    /// Records that `id` successfully started a new run, clearing the previous run's
    /// exit state. A stop or removal still in flight when the start completed is
    /// preserved: lifecycle operations are not serialized, so a `docker stop` /
    /// `docker rm` that landed mid-start must survive the start that raced it. A
    /// stop that already completed is superseded — that is how a sequential
    /// stop-then-start (and a recovery restore) keeps its fresh lifecycle.
    func recordStarted(id: String) throws {
        try mutate { document in
            document.lifecycles[id] = Self.freshRunRecord(after: document.lifecycles[id], restartAttempts: nil)
        }
    }

    /// Records that `id` was observed running during daemon recovery while preserving pending stop/remove intent.
    func recordObservedRunning(id: String) throws {
        try mutate { document in
            var record = document.lifecycles[id] ?? RestartLifecycleRecord(restartAttempts: nil)
            record.hasStarted = true
            if record.pendingAction == .start {
                record.manuallyStopped = false
                record.pendingAction = nil
            }
            record.lastExitCode = nil
            document.lifecycles[id] = record
        }
    }

    /// Records that an automatic restart attempt is about to start for `id`.
    func recordRestartIntent(id: String, attempt: Int) throws {
        guard (0..<Int.max).contains(attempt) else { throw PersistenceError.invalidRestartAttempts }
        try mutate { document in
            document.lifecycles[id, default: RestartLifecycleRecord()].pendingAction = .start
            document.lifecycles[id, default: RestartLifecycleRecord()].restartAttempts = attempt
        }
    }

    /// Records that automatic restart `attempt` completed for `id`.
    func recordRestarted(id: String, attempt: Int) throws {
        guard (0..<Int.max).contains(attempt) else { throw PersistenceError.invalidRestartAttempts }
        try mutate { document in
            document.lifecycles[id] = Self.freshRunRecord(after: document.lifecycles[id], restartAttempts: attempt)
        }
    }

    /// A completed run's evidence — its exit code and retry budget — gives way to
    /// the new run, but an unfinished stop or removal outlives it.
    private static func freshRunRecord(after previous: RestartLifecycleRecord?, restartAttempts: Int?) -> RestartLifecycleRecord {
        var record = RestartLifecycleRecord(hasStarted: true, manuallyStopped: false, pendingAction: nil, restartAttempts: restartAttempts ?? 0)
        if let previous, previous.pendingAction == .stop || previous.pendingAction == .remove {
            record.manuallyStopped = previous.manuallyStopped
            record.pendingAction = previous.pendingAction
        }
        return record
    }

    /// Records that the user explicitly requested a stop or kill for `id`.
    func recordStopIntent(id: String, hasStarted: Bool) throws {
        try mutate { document in
            var record = document.lifecycles[id] ?? RestartLifecycleRecord()
            record.hasStarted = record.hasStarted || hasStarted
            record.manuallyStopped = true
            record.pendingAction = .stop
            document.lifecycles[id] = record
        }
    }

    /// Records that a manual stop operation finished for `id`.
    func recordStopped(id: String) throws {
        try mutate { document in
            document.lifecycles[id, default: RestartLifecycleRecord()].pendingAction = nil
        }
    }

    /// Commits the container's real final exit code for the run that just ended.
    func recordExit(id: String, code: Int32) throws {
        try mutate { document in
            guard document.lifecycles[id] != nil else { return }
            document.lifecycles[id]?.lastExitCode = code
        }
    }

    /// Records that container removal is in progress for `id`.
    func recordRemoveIntent(id: String) throws {
        try mutate { document in
            document.lifecycles[id, default: RestartLifecycleRecord()].pendingAction = .remove
        }
    }

    /// Removes any persisted policy override and lifecycle record for `id`.
    func remove(id: String) {
        guard document.overrides[id] != nil || document.lifecycles[id] != nil else { return }
        do {
            try mutate { document in
                document.overrides.removeValue(forKey: id)
                document.lifecycles.removeValue(forKey: id)
            }
        } catch {
            log.error("could not remove restart metadata for \(id): \(error)")
        }
    }

    private func mutate(_ update: (inout Document) -> Void) throws {
        if let configurationError { throw configurationError }
        var next = document
        update(&next)
        if let fileURL {
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        }
        document = next
    }
}

extension RestartPolicyManager {
    /// Returns the effective restart policy for `hexId`, preferring a persisted override over create-time labels.
    static func effectivePolicy(hexId: String, labels: [String: String]) async -> RestartPolicy? {
        await RestartPolicyOverrideStore.shared.get(id: hexId) ?? decode(from: labels)
    }
}
