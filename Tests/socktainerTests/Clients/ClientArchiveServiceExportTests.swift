import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import socktainer

@Suite("ClientArchiveService.exportRootfs")
struct ClientArchiveServiceExportTests {

    @Test("a container's ext4 rootfs exports a tar preserving its files and directory structure")
    func exportsRootfsContents() async throws {
        let fixture = ExportFixture()
        defer { fixture.cleanUp() }
        try fixture.writeExt4Rootfs(
            containerId: "web",
            files: ["/hello.txt": "exported by socktainer\n", "/etc/hostname": "web\n"])

        let tarURL = try await fixture.service.exportRootfs(containerId: "web")
        defer { try? FileManager.default.removeItem(at: tarURL) }

        let extracted = fixture.appSupport.appendingPathComponent("extracted")
        try ArchiveUtility.extract(tarPath: tarURL, to: extracted)
        let hello = try #require(firstFile(named: "hello.txt", under: extracted), "exported tar must carry hello.txt")
        let hostname = try #require(firstFile(named: "hostname", under: extracted), "exported tar must carry etc/hostname")
        #expect(try String(contentsOf: hello, encoding: .utf8) == "exported by socktainer\n")
        #expect(try String(contentsOf: hostname, encoding: .utf8) == "web\n")
    }

    @Test("a container without a rootfs file throws rootfsNotFound")
    func missingRootfs() async throws {
        let fixture = ExportFixture()
        defer { fixture.cleanUp() }

        do {
            _ = try await fixture.service.exportRootfs(containerId: "ghost")
            Issue.record("export of a container with no rootfs must throw")
        } catch let error as ClientArchiveError {
            guard case .rootfsNotFound(let id) = error else {
                Issue.record("expected rootfsNotFound, got \(error)")
                return
            }
            #expect(id == "ghost")
        }
    }

    @Test("an unreadable rootfs surfaces as operationFailed with the container id, not a raw EXT4 error")
    func corruptRootfs() async throws {
        let fixture = ExportFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRawRootfs(containerId: "broken", bytes: Data("not an ext4 filesystem".utf8))

        do {
            _ = try await fixture.service.exportRootfs(containerId: "broken")
            Issue.record("export of a corrupt rootfs must throw")
        } catch let error as ClientArchiveError {
            guard case .operationFailed(let message) = error else {
                Issue.record("expected operationFailed, got \(error)")
                return
            }
            #expect(message.contains("broken"))
        }
    }
}

private struct ExportFixture {
    let appSupport: URL
    let service: ClientArchiveService

    init() {
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
        service = ClientArchiveService(appSupportPath: appSupport)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    func writeExt4Rootfs(containerId: String, files: [String: String]) throws {
        let formatter = try EXT4.Formatter(FilePath(rootfs(containerId).path))
        for (path, contents) in files {
            let stream = InputStream(data: Data(contents.utf8))
            stream.open()
            try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
        }
        try formatter.close()
    }

    func writeRawRootfs(containerId: String, bytes: Data) throws {
        try bytes.write(to: rootfs(containerId))
    }

    private func rootfs(_ containerId: String) -> URL {
        let dir = appSupport.appendingPathComponent("containers/\(containerId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rootfs.ext4")
    }
}

private func firstFile(named name: String, under directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return nil
    }
    return enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent == name }
}
