import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("PreStartInjectionStore reports what it cannot read")
struct PreStartInjectionStoreTests {

    private func temporaryStorage() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-prestart-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a container with nothing staged has no mounts")
    func nothingStagedIsNotAnError() async throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = PreStartInjectionStore()
        await store.configure(storageDirectory: storage, logger: Logger(label: "test"))

        #expect(try await store.mounts(containerId: "never-touched").isEmpty)
    }

    @Test("a staged file becomes one mount at its guest path")
    func stagedFileBecomesAMount() async throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let source = storage.appendingPathComponent("payload")
        try Data("key".utf8).write(to: source)

        let store = PreStartInjectionStore()
        await store.configure(storageDirectory: storage, logger: Logger(label: "test"))
        try await store.stage(
            containerId: "c1", guestPath: "/etc/keys/service.key", source: source, mode: 0o600)

        let mounts = try await store.mounts(containerId: "c1")
        #expect(mounts.count == 1)
        #expect(mounts.first?.destination == "/etc/keys/service.key")
    }

    @Test("staging the same path again replaces it and keeps one entry")
    func restagingReplacesInPlace() async throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let first = storage.appendingPathComponent("first")
        let second = storage.appendingPathComponent("second")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let store = PreStartInjectionStore()
        await store.configure(storageDirectory: storage, logger: Logger(label: "test"))
        try await store.stage(containerId: "c1", guestPath: "/etc/k", source: first, mode: 0o600)
        try await store.stage(containerId: "c1", guestPath: "/etc/k", source: second, mode: 0o600)

        let staged = try await store.pending(containerId: "c1")
        #expect(staged.count == 1)
        let contents = try Data(contentsOf: URL(fileURLWithPath: staged[0].hostPath))
        #expect(String(decoding: contents, as: UTF8.self) == "two")
    }

    @Test("an unreadable manifest is reported, not read as nothing staged")
    func unreadableManifestThrows() async throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let source = storage.appendingPathComponent("payload")
        try Data("key".utf8).write(to: source)

        let store = PreStartInjectionStore()
        await store.configure(storageDirectory: storage, logger: Logger(label: "test"))
        try await store.stage(
            containerId: "c1", guestPath: "/etc/keys/service.key", source: source, mode: 0o600)

        let manifest =
            storage
            .appendingPathComponent("socktainer-prestart")
            .appendingPathComponent("c1")
            .appendingPathComponent("manifest.json")
        try Data("not json".utf8).write(to: manifest)

        await #expect(throws: PreStartInjectionError.self) {
            _ = try await store.mounts(containerId: "c1")
        }
    }
}
