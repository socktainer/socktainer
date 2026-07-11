import Foundation
import Logging

/// Restart policies are baked into container labels at create time and Apple
/// Container's configuration is immutable afterwards — `docker update` therefore
/// records an override here, consulted before the label. Persisted so overrides
/// survive daemon restarts, like the labels they shadow.
///
/// Keyed by the instance-unique Docker hex id (name + creation date), never the
/// reusable native name: a recreated container gets a fresh key, so a stale
/// entry can never apply to the wrong instance — removal is hygiene, not
/// correctness.
actor RestartPolicyOverrideStore {
    static let shared = RestartPolicyOverrideStore()

    private var overrides: [String: RestartPolicy] = [:]
    private var fileURL: URL?
    private let log = Logger(label: "socktainer.restart-policy-overrides")

    func configure(storageDirectory: URL) {
        let url = storageDirectory.appendingPathComponent("socktainer-restart-policy-overrides.json")
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            overrides = try JSONDecoder().decode([String: RestartPolicy].self, from: Data(contentsOf: url))
        } catch {
            log.error("could not load restart-policy overrides from \(url.path) — updates recorded by earlier runs are not applied: \(error)")
        }
    }

    func set(id: String, policy: RestartPolicy) {
        overrides[id] = policy
        persist()
    }

    func get(id: String) -> RestartPolicy? {
        overrides[id]
    }

    func remove(id: String) {
        guard overrides.removeValue(forKey: id) != nil else { return }
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try JSONEncoder().encode(overrides).write(to: fileURL, options: .atomic)
        } catch {
            log.error("could not persist restart-policy overrides to \(fileURL.path) — the change is in effect but will not survive a daemon restart: \(error)")
        }
    }
}

extension RestartPolicyManager {
    static func effectivePolicy(hexId: String, labels: [String: String]) async -> RestartPolicy? {
        await RestartPolicyOverrideStore.shared.get(id: hexId) ?? decode(from: labels)
    }
}
