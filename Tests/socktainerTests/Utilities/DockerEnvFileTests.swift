import ContainerResource
import Foundation
import Testing

@testable import socktainer

@Suite("DockerEnvFile")
struct DockerEnvFileTests {

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dockerenv-test-\(UUID().uuidString)")
    }

    @Test("Adds a read-only /.dockerenv mount backed by an empty host file")
    func addsMarkerMount() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mount = try #require(try DockerEnvFile.mount(existing: [], readOnlyRootfs: false, root: root))

        #expect(mount.isVirtiofs)
        #expect(mount.destination == "/.dockerenv")
        #expect(mount.options.readonly)
        let file = root.appendingPathComponent(DockerEnvFile.fileName)
        #expect(mount.source == file.path)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test("Reuses the existing host file across containers")
    func reusesHostFile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try DockerEnvFile.ensureFile(in: root)
        let second = try DockerEnvFile.ensureFile(in: root)

        #expect(first == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [DockerEnvFile.fileName])
    }

    @Test("Adds the marker next to unrelated mounts")
    func injectsAlongsideOtherMounts() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let existing: [Filesystem] = [
            .virtiofs(source: "/tmp/host-dir", destination: "/mnt/host", options: []),
            .virtiofs(source: "/tmp/docker.sock", destination: "/var/run/docker.sock", options: []),
            .tmpfs(destination: "/run", options: []),
        ]
        #expect(try DockerEnvFile.mount(existing: existing, readOnlyRootfs: false, root: root)?.destination == "/.dockerenv")
    }

    @Test("Leaves a client-supplied /.dockerenv in place")
    func clientMountWins() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let own = Filesystem.virtiofs(source: "/tmp/my-dockerenv", destination: "/.dockerenv", options: [])
        #expect(try DockerEnvFile.mount(existing: [own], readOnlyRootfs: false, root: root) == nil)
        let ownWithSlash = Filesystem.virtiofs(source: "/tmp/my-dockerenv", destination: "/.dockerenv/", options: [])
        #expect(try DockerEnvFile.mount(existing: [ownWithSlash], readOnlyRootfs: false, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Honours a client /.dockerenv written with . and .. components")
    func clientMountWithDotComponentsWins() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for destination in ["/var/../.dockerenv", "//.dockerenv", "/./.dockerenv", "/../.dockerenv", "/a/./b/../../.dockerenv"] {
            let own = Filesystem.virtiofs(source: "/tmp/my-dockerenv", destination: destination, options: [])
            #expect(try DockerEnvFile.mount(existing: [own], readOnlyRootfs: false, root: root) == nil, "\(destination)")
        }
    }

    @Test("Normalizes guest paths without following host symlinks")
    func normalizesLexically() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // On the host, `link/..` resolves through the symlink to `real`; lexically it is `root`.
        let real = root.appendingPathComponent("real/deep")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: real)
        try Data().write(to: root.appendingPathComponent("real/file"))

        #expect(DockerEnvFile.normalized(root.path + "/link/../file") == root.path + "/file")
    }

    @Test("Skips the marker for a read-only root filesystem")
    func skipsReadOnlyRootfs() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try DockerEnvFile.mount(existing: [], readOnlyRootfs: true, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Hides only the marker from reported mounts")
    func reportsClientMountsOnly() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = try #require(try DockerEnvFile.mount(existing: [], readOnlyRootfs: false, root: root))
        let own = Filesystem.virtiofs(source: "/tmp/my-dockerenv", destination: "/.dockerenv", options: [])
        let data = Filesystem.virtiofs(source: "/tmp/host-dir", destination: "/mnt/host", options: [])

        #expect(DockerEnvFile.isMarker(marker, root: root))
        #expect(!DockerEnvFile.isMarker(own, root: root))
        #expect(!DockerEnvFile.isMarker(data, root: root))
        let markerAtDefaultRoot = Filesystem.virtiofs(
            source: DockerEnvFile.root.appendingPathComponent(DockerEnvFile.fileName).path,
            destination: DockerEnvFile.guestPath, options: ["ro"])
        #expect(DockerEnvFile.reported([data, markerAtDefaultRoot, own]).map(\.source) == ["/tmp/host-dir", "/tmp/my-dockerenv"])
    }
}
