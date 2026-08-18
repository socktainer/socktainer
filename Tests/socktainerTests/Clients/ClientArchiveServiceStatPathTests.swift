import ContainerAPIClient
import ContainerResource
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import socktainer

@Suite("ClientArchiveService.statPath")
struct ClientArchiveServiceStatPathTests {

    @Test("a file reports the same stat getArchive would return")
    func matchesGetArchiveForAFile() async throws {
        let fixture = StatPathFixture()
        defer { fixture.cleanUp() }
        try fixture.writeExt4Rootfs(containerId: "web", files: ["/hello.txt": "exported\n"])

        let stat = try await fixture.service.statPath(container: fixture.makeContainer(id: "web"), path: "/hello.txt")
        let (_, viaArchive) = try await fixture.service.getArchive(container: fixture.makeContainer(id: "web"), path: "/hello.txt")

        #expect(stat.name == viaArchive.name)
        #expect(stat.size == viaArchive.size)
        #expect(stat.mode == viaArchive.mode)
        #expect(stat.mtime == viaArchive.mtime)
    }

    @Test("a directory reports the same stat getArchive would return")
    func matchesGetArchiveForADirectory() async throws {
        let fixture = StatPathFixture()
        defer { fixture.cleanUp() }
        try fixture.writeExt4Rootfs(containerId: "web", files: ["/etc/hostname": "web\n"])

        let stat = try await fixture.service.statPath(container: fixture.makeContainer(id: "web"), path: "/etc")
        let (_, viaArchive) = try await fixture.service.getArchive(container: fixture.makeContainer(id: "web"), path: "/etc")

        #expect(stat.name == viaArchive.name)
        #expect(stat.mode == viaArchive.mode)
    }

    @Test("a path that is not there throws pathNotFound")
    func missingPath() async throws {
        let fixture = StatPathFixture()
        defer { fixture.cleanUp() }
        try fixture.writeExt4Rootfs(containerId: "web", files: ["/hello.txt": "hi\n"])

        do {
            _ = try await fixture.service.statPath(container: fixture.makeContainer(id: "web"), path: "/absent")
            Issue.record("statting a path that is not there must throw")
        } catch let error as ClientArchiveError {
            guard case .pathNotFound = error else {
                Issue.record("expected pathNotFound, got \(error)")
                return
            }
        }
    }

    @Test("a container without a rootfs file throws rootfsNotFound")
    func missingRootfs() async throws {
        let fixture = StatPathFixture()
        defer { fixture.cleanUp() }

        do {
            _ = try await fixture.service.statPath(container: fixture.makeContainer(id: "ghost"), path: "/")
            Issue.record("statting a container with no rootfs must throw")
        } catch let error as ClientArchiveError {
            guard case .rootfsNotFound = error else {
                Issue.record("expected rootfsNotFound, got \(error)")
                return
            }
        }
    }
}

private struct StatPathFixture {
    let appSupport: URL
    let service: ClientArchiveService

    init() {
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stat-path-test-\(UUID().uuidString)")
        service = ClientArchiveService(appSupportPath: appSupport)
    }

    /// A stopped container whose rootfs lives at the legacy per-container path.
    func makeContainer(id: String) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "busybox:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        return ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: img, process: proc),
            status: .stopped, networks: [], startedDate: nil
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    func writeExt4Rootfs(containerId: String, files: [String: String]) throws {
        let formatter = try EXT4.Formatter(FilePath(rootfs(containerId).path))
        for (path, contents) in files {
            let stream = InputStream(data: Data(contents.utf8))
            stream.open()
            try formatter.create(
                path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
        }
        try formatter.close()
    }

    private func rootfs(_ containerId: String) -> URL {
        let dir = appSupport.appendingPathComponent("containers/\(containerId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rootfs.ext4")
    }
}
