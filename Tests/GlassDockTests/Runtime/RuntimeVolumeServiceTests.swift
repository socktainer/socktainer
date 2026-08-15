import Foundation
import Testing

@testable import GlassDock

@Suite("Persistent runtime volumes")
struct RuntimeVolumeServiceTests {
    @Test("creates directory-backed data and restores metadata")
    func createsAndRestores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RuntimeVolumeService(root: root)
        let created = try await first.create(
            request: RESTVolumeCreate(
                Name: "database", Driver: "local", Options: ["sync": "fsync"],
                Labels: ["purpose": "test"]
            )
        )
        try Data("durable".utf8).write(
            to: URL(fileURLWithPath: created.Mountpoint).appendingPathComponent("value")
        )

        let restored = try await RuntimeVolumeService(root: root).inspect(name: "database")

        #expect(restored.Name == "database")
        #expect(restored.Labels == ["purpose": "test"])
        #expect(restored.Options == ["sync": "fsync"])
        #expect(
            try String(
                contentsOf: URL(fileURLWithPath: restored.Mountpoint).appendingPathComponent("value"),
                encoding: .utf8
            ) == "durable"
        )
    }

    @Test("rejects traversal and non-local drivers")
    func rejectsUnsafeConfiguration() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RuntimeVolumeService(root: root)

        await #expect(throws: (any Error).self) {
            _ = try await service.create(
                request: RESTVolumeCreate(Name: "../escape", Driver: "local", Options: [:], Labels: nil)
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await service.create(
                request: RESTVolumeCreate(Name: "remote", Driver: "nfs", Options: [:], Labels: nil)
            )
        }
    }

    @Test("does not delete a volume that a live container references")
    func protectsLiveReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RuntimeVolumeService(root: root)
        _ = try await service.create(
            request: RESTVolumeCreate(Name: "database", Driver: "local", Options: [:], Labels: nil)
        )
        try await service.retain(names: ["database"], containerID: "container-1")
        await service.setReferenceValidator { $0 == "container-1" }

        await #expect(throws: (any Error).self) {
            try await service.deleteIfUnused(name: "database")
        }

        await service.setReferenceValidator { _ in false }
        try await service.deleteIfUnused(name: "database")
        await #expect(throws: (any Error).self) {
            _ = try await service.inspect(name: "database")
        }
    }

    @Test("reads metadata from before reference tracking")
    func readsLegacyMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RuntimeVolumeService(root: root)
        _ = try await service.create(
            request: RESTVolumeCreate(Name: "legacy", Driver: "local", Options: [:], Labels: nil)
        )
        let metadataURL = root.appendingPathComponent("legacy/metadata.json")
        var metadata = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        metadata.removeValue(forKey: "referencedContainers")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

        #expect(try await service.inspect(name: "legacy").Name == "legacy")
    }
}
