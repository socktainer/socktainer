import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import socktainer

@Suite("ClientArchiveService.getArchive on never-started containers")
struct ClientArchiveServicePreStartTests {

    @Test("a created-never-started container serves image content from its shared snapshot")
    func neverStartedContainerServesImageContentFromSnapshot() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(
            digest: "abc123",
            files: ["/etc/passwd": "root:x:0:0:root\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, stat) = try await fixture.service.getArchive(container: container, path: "/etc/passwd")

        #expect(stat.name == "passwd")
        #expect(stat.size == 16)
        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let file = try #require(firstFile(named: "passwd", under: extracted))
        #expect(try String(contentsOf: file, encoding: .utf8) == "root:x:0:0:root\n")
    }

    @Test("a path absent from the snapshot throws pathNotFound")
    func missingPathInSnapshotThrowsPathNotFound() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/etc/passwd": "root:x:0:0:root\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        do {
            _ = try await fixture.service.getArchive(container: container, path: "/nonexistent")
            Issue.record("expected pathNotFound")
        } catch let error as ClientArchiveError {
            guard case .pathNotFound = error else {
                Issue.record("expected pathNotFound, got \(error)")
                return
            }
        }
    }

    @Test("a container's own rootfs.ext4 wins over the image snapshot when both exist")
    func rootfsExt4WinsWhenBothExist() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/data.txt": "image-content\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        try fixture.writeRootfs(containerId: "web", files: ["/data.txt": "writable-content\n"])
        let container = try fixture.makeContainer(id: "web", status: .stopped, startedDate: Date())

        let (tarData, _) = try await fixture.service.getArchive(container: container, path: "/data.txt")

        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let file = try #require(firstFile(named: "data.txt", under: extracted))
        #expect(try String(contentsOf: file, encoding: .utf8) == "writable-content\n")
    }

    @Test("a started container without a rootfs.ext4 throws rootfsNotFound instead of falling back")
    func startedContainerWithoutRootfsThrowsRootfsNotFound() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/etc/passwd": "root:x:0:0:root\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web", status: .stopped, startedDate: Date())

        do {
            _ = try await fixture.service.getArchive(container: container, path: "/etc/passwd")
            Issue.record("expected rootfsNotFound for a started container whose rootfs is gone")
        } catch let error as ClientArchiveError {
            guard case .rootfsNotFound(let id) = error else {
                Issue.record("expected rootfsNotFound, got \(error)")
                return
            }
            #expect(id == "web")
        }
    }

    @Test("a running container is unaffected and reads its own rootfs.ext4")
    func runningContainerReadsRootfs() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeRootfs(containerId: "web", files: ["/live.txt": "live\n"])
        let container = try fixture.makeContainer(id: "web", status: .running, startedDate: Date())

        let (tarData, _) = try await fixture.service.getArchive(container: container, path: "/live.txt")

        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let file = try #require(firstFile(named: "live.txt", under: extracted))
        #expect(try String(contentsOf: file, encoding: .utf8) == "live\n")
    }

    @Test("a missing runtime-configuration.json throws rootfsNotFound, not a crash")
    func missingRuntimeConfigThrowsRootfsNotFound() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        let container = try fixture.makeContainer(id: "web")

        do {
            _ = try await fixture.service.getArchive(container: container, path: "/etc/passwd")
            Issue.record("expected rootfsNotFound")
        } catch let error as ClientArchiveError {
            guard case .rootfsNotFound = error else {
                Issue.record("expected rootfsNotFound, got \(error)")
                return
            }
        }
    }

    @Test("a malformed runtime-configuration.json throws rootfsNotFound, not a crash")
    func malformedRuntimeConfigThrowsRootfsNotFound() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeRawRuntimeConfig(containerId: "web", contents: "not json at all")
        let container = try fixture.makeContainer(id: "web")

        do {
            _ = try await fixture.service.getArchive(container: container, path: "/etc/passwd")
            Issue.record("expected rootfsNotFound")
        } catch let error as ClientArchiveError {
            guard case .rootfsNotFound = error else {
                Issue.record("expected rootfsNotFound, got \(error)")
                return
            }
        }
    }

    @Test("a runtime-config source pointing at a missing snapshot throws rootfsNotFound")
    func missingSnapshotSourceThrowsRootfsNotFound() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "nonexistent-digest")
        let container = try fixture.makeContainer(id: "web")

        do {
            _ = try await fixture.service.getArchive(container: container, path: "/etc/passwd")
            Issue.record("expected rootfsNotFound")
        } catch let error as ClientArchiveError {
            guard case .rootfsNotFound = error else {
                Issue.record("expected rootfsNotFound, got \(error)")
                return
            }
        }
    }

    @Test("a directory is served from the snapshot with its full tree")
    func directoryFromSnapshot() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(
            digest: "abc123",
            files: ["/etc/passwd": "root:x:0:0:root\n", "/etc/hostname": "web\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, stat) = try await fixture.service.getArchive(container: container, path: "/etc")

        #expect(stat.name == "etc")
        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let passwd = try #require(firstFile(named: "passwd", under: extracted))
        let hostname = try #require(firstFile(named: "hostname", under: extracted))
        #expect(try String(contentsOf: passwd, encoding: .utf8) == "root:x:0:0:root\n")
        #expect(try String(contentsOf: hostname, encoding: .utf8) == "web\n")
    }

    @Test("a file archive is exactly one basename entry, like moby — no ./ directory entry")
    func singleEntryTarForFile() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/etc/passwd": "root:x:0:0:root\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, _) = try await fixture.service.getArchive(container: container, path: "/etc/passwd")

        // Regression guard for the OpenShell first-entry bug: the tar must
        // contain exactly one entry named after the basename — the previous
        // directory-wrapped form ("./" entry first) made first-entry
        // consumers extract an empty directory instead of the file.
        let entries = try fixture.tarEntries(tarData)
        #expect(entries.count == 1)
        #expect(entries[0].path == "passwd")
        #expect(entries[0].type == .regular)
    }

    @Test("a symlink archive is exactly one symlink entry, like moby")
    func singleEntryTarForSymlink() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/etc/passwd": "root:x:0:0:root\n"], links: ["/etc/passwd-link": "/etc/passwd"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, _) = try await fixture.service.getArchive(container: container, path: "/etc/passwd-link")

        let entries = try fixture.tarEntries(tarData)
        #expect(entries.count == 1)
        #expect(entries[0].path == "passwd-link")
        #expect(entries[0].type == .symbolicLink)
    }

    @Test("a symlink in the snapshot is served as a symlink, dangling included")
    func symlinkFromSnapshot() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(
            digest: "abc123",
            files: ["/etc/passwd": "root:x:0:0:root\n"],
            links: ["/etc/passwd-link": "/etc/passwd", "/etc/dangling-link": "/nonexistent"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, stat) = try await fixture.service.getArchive(container: container, path: "/etc/passwd-link")

        #expect(stat.linkTarget == "/etc/passwd")
        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let link = try #require(firstFile(named: "passwd-link", under: extracted))
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        #expect(isLink, "tar entry must be a symlink, not a regular file")

        let (danglingTar, danglingStat) = try await fixture.service.getArchive(container: container, path: "/etc/dangling-link")
        #expect(danglingStat.linkTarget == "/nonexistent")
        let danglingExtracted = try fixture.extractTar(danglingTar)
        defer { try? FileManager.default.removeItem(at: danglingExtracted) }
        let danglingLink = try #require(firstFile(named: "dangling-link", under: danglingExtracted))
        let danglingIsLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: danglingLink.path)) != nil
        #expect(danglingIsLink, "a dangling symlink must still be served as a symlink, like moby")
    }

    @Test("the snapshot root can be served")
    func rootFromSnapshot() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/etc/passwd": "root:x:0:0:root\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, _) = try await fixture.service.getArchive(container: container, path: "/")

        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let passwd = try #require(firstFile(named: "passwd", under: extracted))
        #expect(try String(contentsOf: passwd, encoding: .utf8) == "root:x:0:0:root\n")
    }

    @Test("an empty file in the snapshot is served")
    func emptyFileFromSnapshot() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/empty.txt": ""])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, stat) = try await fixture.service.getArchive(container: container, path: "/empty.txt")

        #expect(stat.size == 0)
        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let file = try #require(firstFile(named: "empty.txt", under: extracted))
        #expect(try String(contentsOf: file, encoding: .utf8).isEmpty)
    }

    @Test("path traversal resolves inside the rootfs, mirroring moby's path cleaning")
    func traversalResolvesInsideRootfs() async throws {
        let fixture = PreStartFixture()
        defer { fixture.cleanUp() }

        try fixture.writeSnapshot(digest: "abc123", files: ["/etc/passwd": "root:x:0:0:root\n"])
        try fixture.writeRuntimeConfig(containerId: "web", snapshotDigest: "abc123")
        let container = try fixture.makeContainer(id: "web")

        let (tarData, stat) = try await fixture.service.getArchive(container: container, path: "/../etc/passwd")

        #expect(stat.name == "passwd")
        let extracted = try fixture.extractTar(tarData)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let file = try #require(firstFile(named: "passwd", under: extracted))
        #expect(try String(contentsOf: file, encoding: .utf8) == "root:x:0:0:root\n")
    }
}

// MARK: - Fixture

private struct PreStartFixture {
    let appSupport: URL
    let service: ClientArchiveService

    init() {
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("prestart-\(UUID().uuidString)")
        service = ClientArchiveService(appSupportPath: appSupport)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    func makeContainer(id: String, status: RuntimeStatus = .stopped, startedDate: Date? = nil) throws -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "busybox:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        let config = ContainerConfiguration(id: id, image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: status, networks: [], startedDate: startedDate)
    }

    /// Build an ext4 snapshot under snapshots/<digest>/snapshot (the layout
    /// Apple Container produces at image create time).
    func writeSnapshot(digest: String, files: [String: String], links: [String: String] = [:]) throws {
        let dir = appSupport.appendingPathComponent("snapshots/\(digest)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = try EXT4.Formatter(FilePath(dir.appendingPathComponent("snapshot").path))
        for (path, contents) in files {
            let stream = InputStream(data: Data(contents.utf8))
            stream.open()
            try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
            stream.close()
        }
        for (path, target) in links {
            try formatter.create(path: FilePath(path), link: FilePath(target), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777), recursion: true)
        }
        try formatter.close()
    }

    /// Write a container's runtime-configuration.json pointing at the snapshot.
    func writeRuntimeConfig(containerId: String, snapshotDigest: String) throws {
        let source =
            appSupport
            .appendingPathComponent("snapshots/\(snapshotDigest)")
            .appendingPathComponent("snapshot")
            .path
        let json = """
            {"containerRootFilesystem":{"source":"\(source)","type":{"block":{"cache":{"on":{}},"format":"ext4","sync":{"fsync":{}}}},"options":[],"destination":"/","attachments":[]}}
            """
        try writeRawRuntimeConfig(containerId: containerId, contents: json)
    }

    func writeRawRuntimeConfig(containerId: String, contents: String) throws {
        let dir = appSupport.appendingPathComponent("containers/\(containerId)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(
            to: dir.appendingPathComponent("runtime-configuration.json"),
            atomically: true,
            encoding: .utf8)
    }

    /// Write a container's private rootfs.ext4 (as Apple provisions it at start).
    func writeRootfs(containerId: String, files: [String: String]) throws {
        let dir = appSupport.appendingPathComponent("containers/\(containerId)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = try EXT4.Formatter(FilePath(dir.appendingPathComponent("rootfs.ext4").path))
        for (path, contents) in files {
            let stream = InputStream(data: Data(contents.utf8))
            stream.open()
            try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
            stream.close()
        }
        try formatter.close()
    }

    /// Parse a tar's entries (path + file type) via ArchiveReader — unlike
    /// filesystem extraction this sees the raw entry list, so it can assert
    /// there is no leading "./" directory entry.
    func tarEntries(_ data: Data) throws -> [(path: String, type: URLFileResourceType)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("entries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tarPath = dir.appendingPathComponent("archive.tar")
        try data.write(to: tarPath)
        let reader = try ArchiveReader(file: tarPath)
        return reader.makeStreamingIterator().map { entry, _ in (entry.path ?? "", entry.fileType) }
    }

    func extractTar(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("extract-\(UUID().uuidString)")
        let tarPath = dir.appendingPathComponent("archive.tar")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: tarPath)
        let out = dir.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tarPath, to: out)
        return out
    }
}

private func firstFile(named name: String, under directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return nil
    }
    return enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent == name }
}
