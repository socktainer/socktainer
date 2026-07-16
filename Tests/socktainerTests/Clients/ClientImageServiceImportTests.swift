import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import Testing

@testable import socktainer

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
        let config = try await stored.config(for: Platform(arch: "arm64", os: "linux"))
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

        let allImages = try await ImageStore(path: fixture.storeDir).list()
        #expect(allImages.contains { $0.digest == digest })
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
}

private struct ImportFixture {
    let workDir: URL
    let rootfsDir: URL
    let storeDir: URL
    let service = ClientImageService(containerSystemConfig: ContainerSystemConfig())
    let logger = Logger(label: "test")

    init() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("image-import-\(UUID().uuidString)")
        rootfsDir = workDir.appendingPathComponent("rootfs")
        storeDir = workDir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: rootfsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
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
