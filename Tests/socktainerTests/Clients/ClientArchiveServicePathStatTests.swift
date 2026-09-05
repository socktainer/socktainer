import ContainerAPIClient
import ContainerResource
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import socktainer

@Suite("ClientArchiveService path-stat header")
struct ClientArchiveServicePathStatTests {

    @Test("a directory carries the ModeDir bit clients test with IsDir()")
    func directoryCarriesModeDir() async throws {
        let fixture = PathStatFixture()
        defer { fixture.cleanUp() }
        try fixture.writeExt4Rootfs(containerId: "web", files: ["/etc/hostname": "web\n"])

        let (_, stat) = try await fixture.service.getArchive(container: fixture.makeContainer(id: "web"), path: "/etc")

        #expect(stat.mode & (1 << 31) != 0)
        #expect(stat.mode & 0o777 == 0o755)
    }

    @Test("a regular file carries permission bits and no type bit")
    func regularFileCarriesNoTypeBit() async throws {
        let fixture = PathStatFixture()
        defer { fixture.cleanUp() }
        try fixture.writeExt4Rootfs(containerId: "web", files: ["/hello.txt": "hi\n"])

        let (_, stat) = try await fixture.service.getArchive(container: fixture.makeContainer(id: "web"), path: "/hello.txt")

        #expect(stat.mode == 0o644)
    }

    @Test("every POSIX file type maps to the bit Go uses for it")
    func translatesEveryFileType() {
        #expect(goFileMode(posixMode: 0o040755) == (1 << 31) | 0o755)
        #expect(goFileMode(posixMode: 0o120777) == (1 << 27) | 0o777)
        #expect(goFileMode(posixMode: 0o020600) == (1 << 26) | (1 << 21) | 0o600)
        #expect(goFileMode(posixMode: 0o060600) == (1 << 26) | 0o600)
        #expect(goFileMode(posixMode: 0o010600) == (1 << 25) | 0o600)
        #expect(goFileMode(posixMode: 0o140777) == (1 << 24) | 0o777)
        #expect(goFileMode(posixMode: 0o100644) == 0o644)
    }

    @Test("setuid, setgid and sticky survive the translation")
    func translatesPermissionModifiers() {
        #expect(goFileMode(posixMode: 0o104755) == (1 << 23) | 0o755)
        #expect(goFileMode(posixMode: 0o102755) == (1 << 22) | 0o755)
        #expect(goFileMode(posixMode: 0o041777) == (1 << 31) | (1 << 20) | 0o777)
    }

    @Test("a non-symlink reports an empty link target rather than null")
    func nonSymlinkReportsEmptyLinkTarget() async throws {
        let fixture = PathStatFixture()
        defer { fixture.cleanUp() }
        try fixture.writeExt4Rootfs(containerId: "web", files: ["/hello.txt": "hi\n"])

        let (_, stat) = try await fixture.service.getArchive(container: fixture.makeContainer(id: "web"), path: "/hello.txt")

        #expect(stat.linkTarget == "")
        let encoded = try #require(String(data: try JSONEncoder().encode(stat), encoding: .utf8))
        #expect(!encoded.contains("null"))
    }

    @Test("the timestamp reports the daemon's own offset, not Z")
    func timestampUsesLocalOffset() {
        let moment = Date(timeIntervalSince1970: 1_747_098_109)
        let formatted = dockerPathStatTimestamp(moment)

        if TimeZone.current.secondsFromGMT(for: moment) == 0 {
            #expect(formatted.hasSuffix("Z") || formatted.hasSuffix("+00:00"))
        } else {
            #expect(!formatted.hasSuffix("Z"))
        }
    }

    @Test("a whole-second timestamp carries no fraction, as Go omits a zero one")
    func wholeSecondsCarryNoFraction() {
        #expect(!dockerPathStatTimestamp(Date(timeIntervalSince1970: 1_747_098_109)).contains("."))
    }
}

private struct PathStatFixture {
    let appSupport: URL
    let service: ClientArchiveService

    init() {
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "path-stat-test-\(UUID().uuidString)")
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
