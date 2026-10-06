import Foundation
import Vapor

/// Docker names overlay immutable Apple Container IDs. Runtime IDs remain reserved
/// so internal lifecycle operations can continue to address the native container.
actor ContainerNameOverrideStore {
    static let shared = ContainerNameOverrideStore()

    private var names: [String: String] = [:]
    private var fileURL: URL?
    // Actor isolation alone does not serialize the runtime lookup across suspension.
    private let mutations = VMLifecycleAdmission(limit: 1)

    func configure(storageDirectory: URL) throws {
        let url = storageDirectory.appendingPathComponent("socktainer-container-name-overrides.json")
        let loaded =
            FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) : [:]
        guard Set(loaded.values).count == loaded.count else {
            throw Abort(.internalServerError, reason: "Duplicate persisted container names")
        }
        names = loaded
        fileURL = url
    }

    func name(forNativeID nativeID: String) -> String { names[nativeID] ?? nativeID }

    func nativeID(forName name: String) -> String? { names.first { $0.value == name }?.key }

    func snapshot() -> [String: String] { names }

    /// Shares one critical section between create and rename, including their runtime
    /// checks. Image pulls and other create preparation happen outside this section.
    func withAvailableName<T: Sendable>(
        _ name: String,
        excluding nativeID: String? = nil,
        client: ClientContainerProtocol,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await mutations.withSlot {
            let containers = try await client.list(showAll: true, filters: [:])
            var owner = await self.nativeID(forName: name)
            // Native tools may have removed an owner. Resolve through the client,
            // which waits for pre-start replacements, rather than pruning every
            // mapping from a list taken during a transient replacement window.
            if let previousOwner = owner, try await client.getContainer(id: previousOwner) == nil {
                try await self.remove(nativeID: previousOwner)
                owner = nil
            }
            if (owner != nil && owner != nativeID)
                || containers.contains(where: { ($0.id == name || $0.id == ContainerNameUtility.sanitize(name)) && $0.id != nativeID })
            {
                throw Abort(.conflict, reason: "Conflict. The container name \"/\(name)\" is already in use")
            }
            return try await operation()
        }
    }

    func set(nativeID: String, name: String) throws {
        if let owner = self.nativeID(forName: name), owner != nativeID {
            throw Abort(.conflict, reason: "Container name already in use: \(name)")
        }
        var updated = names
        updated[nativeID] = name == nativeID ? nil : name
        try commit(updated)
    }

    func remove(nativeID: String) throws {
        var updated = names
        updated.removeValue(forKey: nativeID)
        try commit(updated)
    }

    func prune(validNativeIDs: Set<String>) throws {
        try commit(names.filter { validNativeIDs.contains($0.key) })
    }

    private func commit(_ updated: [String: String]) throws {
        guard updated != names else { return }
        // Publish only after the atomic write succeeds. A failed rename must not
        // return 204 or leave an in-memory name that disappears on daemon restart.
        if let fileURL {
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        }
        names = updated
    }
}
