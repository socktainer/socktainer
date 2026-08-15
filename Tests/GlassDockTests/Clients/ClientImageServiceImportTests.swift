import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import Testing

@testable import GlassDock

@Suite("ClientImageService import")
struct ClientImageServiceImportTests {

    @Test("importing a tar with a repo:tag registers a queryable image with the right diff_id")
    func importRegistersTaggedImage() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(contents: "hello from import\n")
        let tarData = try Data(contentsOf: tarPath)

        let (reference, digest) = try await fixture.service.importImage(
            tarPath: tarPath,
            repo: "crafted-import",
            tag: "latest",
            message: nil,
            changes: [],
            platform: Platform(arch: "arm64", os: "linux"),
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )

        #expect(reference == "docker.io/library/crafted-import:latest")
        #expect(!digest.isEmpty)

        let stored = try await ImageStore(path: fixture.storeDir).get(reference: "docker.io/library/crafted-import:latest")
        let manifest = try await stored.manifest(
            for: Platform(arch: "arm64", os: "linux")
        )
        let config = try await stored.config(for: Platform(arch: "arm64", os: "linux"))
        #expect(digest == manifest.config.digest)
        #expect(config.rootfs.diffIDs == ["sha256:\(tarData.sha256Hex())"])
    }

    @Test("importing without a repo registers an untagged image")
    func importWithoutRepoIsUntagged() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(contents: "untagged content\n")

        let (reference, digest) = try await fixture.service.importImage(
            tarPath: tarPath,
            repo: nil,
            tag: nil,
            message: nil,
            changes: [],
            platform: Platform(arch: "arm64", os: "linux"),
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )

        #expect(reference == nil)
        #expect(!digest.isEmpty)

        let stored = try #require(
            try await ImageStore(path: fixture.storeDir).list().first
        )
        #expect(
            try await stored.manifest(
                for: Platform(arch: "arm64", os: "linux")
            ).config.digest == digest
        )
    }

    @Test("an omitted tag defaults to latest")
    func repoWithoutTagDefaultsToLatest() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(contents: "default tag content\n")

        let (reference, _) = try await fixture.service.importImage(
            tarPath: tarPath,
            repo: "crafted-default-tag",
            tag: nil,
            message: nil,
            changes: [],
            platform: Platform(arch: "arm64", os: "linux"),
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )

        #expect(reference == "docker.io/library/crafted-default-tag:latest")
    }

    @Test("a digest reference as repo is rejected")
    func digestRepoIsRejected() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(contents: "content\n")
        let digestRepo = "crafted-import@sha256:\(String(repeating: "a", count: 64))"

        do {
            _ = try await fixture.service.importImage(
                tarPath: tarPath,
                repo: digestRepo,
                tag: nil,
                message: nil,
                changes: [],
                platform: Platform(arch: "arm64", os: "linux"),
                appleContainerAppSupportUrl: fixture.storeDir,
                logger: fixture.logger
            )
            Issue.record("expected importImage to throw for a digest reference")
        } catch ClientImageError.digestReferenceNotAllowed(let repo) {
            #expect(repo == digestRepo)
        } catch {
            Issue.record("expected ClientImageError.digestReferenceNotAllowed, got \(error)")
        }
    }

    @Test("re-importing changed content atomically replaces the existing tag")
    func repeatedImportReplacesTag() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }
        let canonical = "docker.io/library/crafted-reimport:latest"

        let (_, oldID) = try await fixture.service.importImage(
            tarPath: fixture.makeTar(contents: "old import\n"),
            repo: "crafted-reimport",
            tag: "latest",
            message: nil,
            changes: [],
            platform: Platform(arch: "arm64", os: "linux"),
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )
        let store = try ImageStore(path: fixture.storeDir)
        let oldRoot = try await store.get(reference: canonical).digest
        let (reference, newID) = try await fixture.service.importImage(
            tarPath: fixture.makeTar(contents: "new import\n"),
            repo: "crafted-reimport",
            tag: "latest",
            message: nil,
            changes: [],
            platform: Platform(arch: "arm64", os: "linux"),
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )

        let newRoot = try await store.get(reference: canonical).digest
        let images = try await store.list()
        #expect(reference == canonical)
        #expect(newID != oldID)
        #expect(newRoot != oldRoot)
        #expect(try await store.get(reference: canonical).digest == newRoot)
        #expect(
            images.contains {
                $0.reference == "moby-dangling@\(oldRoot)"
                    && $0.digest == oldRoot
            }
        )
    }
}

private struct ImportFixture {
    let workDir: URL
    let rootfsDir: URL
    let storeDir: URL
    let service: ClientImageService
    let logger = Logger(label: "test")

    init() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("image-import-\(UUID().uuidString)")
        rootfsDir = workDir.appendingPathComponent("rootfs")
        storeDir = workDir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: rootfsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let localStore = try LocalImageArchiveStore(path: storeDir)
        service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: localStore,
            archiveLoader: localStore
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workDir)
    }

    func makeTar(contents: String) throws -> URL {
        try Data(contents.utf8).write(to: rootfsDir.appendingPathComponent("hello.txt"))
        let tarPath = workDir.appendingPathComponent("import-\(UUID().uuidString).tar")
        try ArchiveUtility.create(tarPath: tarPath, from: rootfsDir)
        return tarPath
    }
}
