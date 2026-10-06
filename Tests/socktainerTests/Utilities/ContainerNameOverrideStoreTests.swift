import Foundation
import Testing

@testable import socktainer

@Suite("ContainerNameOverrideStore")
struct ContainerNameOverrideStoreTests {
    @Test("resolves a Docker-facing name to the native Apple Container name")
    func resolvesAndRemovesOverride() async throws {
        let store = ContainerNameOverrideStore()

        try await store.set(nativeID: "project-web-2-recreate", name: "project-web-2")
        #expect(await store.name(forNativeID: "project-web-2-recreate") == "project-web-2")
        #expect(await store.nativeID(forName: "project-web-2") == "project-web-2-recreate")

        try await store.remove(nativeID: "project-web-2-recreate")
        #expect(await store.name(forNativeID: "project-web-2-recreate") == "project-web-2-recreate")
        #expect(await store.nativeID(forName: "project-web-2") == nil)
    }

    @Test("prunes mappings for containers that no longer exist")
    func prunesRemovedContainers() async throws {
        let store = ContainerNameOverrideStore()
        try await store.set(nativeID: "live", name: "service")
        try await store.set(nativeID: "gone", name: "old-service")

        try await store.prune(validNativeIDs: ["live"])

        #expect(await store.nativeID(forName: "service") == "live")
        #expect(await store.nativeID(forName: "old-service") == nil)
    }
}

@Suite("Container name persistence")
struct ContainerNamePersistenceTests {
    @Test("rename survives reload, renaming back removes the override")
    func reload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContainerNameOverrideStore()
        try await store.configure(storageDirectory: directory)
        try await store.set(nativeID: "temporary", name: "canonical")
        let reopened = ContainerNameOverrideStore()
        try await reopened.configure(storageDirectory: directory)
        #expect(await reopened.nativeID(forName: "canonical") == "temporary")
        try await reopened.set(nativeID: "temporary", name: "temporary")
        try await store.configure(storageDirectory: directory)
        #expect(await store.nativeID(forName: "canonical") == nil)
        #expect(await store.name(forNativeID: "temporary") == "temporary")
    }

    @Test("failed persistence leaves the previous name intact")
    func writeFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ContainerNameOverrideStore()
        try await store.configure(storageDirectory: directory)  // Parent intentionally does not exist.
        await #expect(throws: (any Error).self) {
            try await store.set(nativeID: "temporary", name: "canonical")
        }
        #expect(await store.name(forNativeID: "temporary") == "temporary")
        #expect(await store.nativeID(forName: "canonical") == nil)
    }

    @Test("duplicate persisted names are rejected without losing the active mapping")
    func corruptFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("socktainer-container-name-overrides.json")
        try Data(#"{"one":"canonical","two":"canonical"}"#.utf8).write(to: file)
        let store = ContainerNameOverrideStore()
        try await store.set(nativeID: "original", name: "retained")
        await #expect(throws: (any Error).self) { try await store.configure(storageDirectory: directory) }
        #expect(await store.nativeID(forName: "retained") == "original")
    }
}
