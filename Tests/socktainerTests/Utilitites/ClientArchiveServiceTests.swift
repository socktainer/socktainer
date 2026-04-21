import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import socktainer

struct ClientArchiveServiceTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-service-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a minimal ext4 rootfs at `appSupportPath/containers/{id}/rootfs.ext4`
    /// with `/var/run` pre-created so tests can extract into paths beneath it.
    private func createRootfs(containerId: String, appSupportPath: URL) throws -> URL {
        let containerDir =
            appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let rootfsPath = containerDir.appendingPathComponent("rootfs.ext4")
        let formatter = try EXT4.Formatter(
            FilePath(rootfsPath.path),
            blockSize: 4096,
            minDiskSize: 10 * 1024 * 1024
        )
        try formatter.create(path: FilePath("/var"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/var/run"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.close()

        return rootfsPath
    }

    /// Creates a tar archive containing a single file `hello.txt` with the given content.
    private func createSingleFileTar(content: String, in tempDir: URL) throws -> URL {
        let stagingDir = tempDir.appendingPathComponent("staging-\(UUID().uuidString)")
        let tarPath = tempDir.appendingPathComponent("input-\(UUID().uuidString).tar")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try content.write(
            to: stagingDir.appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8
        )
        try ArchiveUtility.create(tarPath: tarPath, from: stagingDir)
        try? FileManager.default.removeItem(at: stagingDir)
        return tarPath
    }

    private func fileExists(rootfsPath: URL, path: String) throws -> Bool {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        return reader.exists(FilePath(path))
    }

    private func readFile(rootfsPath: URL, path: String) throws -> String {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        let data = try reader.readFile(at: FilePath(path))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - putArchive

    @Test("putArchive creates destination directory and places files when path has no trailing slash")
    func putArchiveNoTrailingSlash() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerId = "c-\(UUID().uuidString)"
        let service = ClientArchiveService(appSupportPath: tempDir)
        let rootfsPath = try createRootfs(containerId: containerId, appSupportPath: tempDir)
        let tarPath = try createSingleFileTar(content: "hello\n", in: tempDir)

        try await service.putArchive(
            containerId: containerId,
            path: "/var/run/act",
            tarPath: tarPath,
            noOverwriteDirNonDir: false
        )

        #expect(try fileExists(rootfsPath: rootfsPath, path: "/var/run/act"))
        #expect(try fileExists(rootfsPath: rootfsPath, path: "/var/run/act/hello.txt"))
        #expect(try readFile(rootfsPath: rootfsPath, path: "/var/run/act/hello.txt") == "hello\n")
    }

    @Test("putArchive creates destination directory and places files when path has trailing slash")
    func putArchiveTrailingSlash() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerId = "c-\(UUID().uuidString)"
        let service = ClientArchiveService(appSupportPath: tempDir)
        let rootfsPath = try createRootfs(containerId: containerId, appSupportPath: tempDir)
        let tarPath = try createSingleFileTar(content: "hello\n", in: tempDir)

        try await service.putArchive(
            containerId: containerId,
            path: "/var/run/act/",
            tarPath: tarPath,
            noOverwriteDirNonDir: false
        )

        #expect(try fileExists(rootfsPath: rootfsPath, path: "/var/run/act/hello.txt"))
        #expect(try readFile(rootfsPath: rootfsPath, path: "/var/run/act/hello.txt") == "hello\n")
    }

    @Test("putArchive preserves pre-existing files in the container")
    func putArchivePreservesExistingFiles() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerId = "c-\(UUID().uuidString)"
        let service = ClientArchiveService(appSupportPath: tempDir)
        let rootfsPath = try createRootfs(containerId: containerId, appSupportPath: tempDir)

        // Add a pre-existing file to the container's /var directory
        let preExistingContent = "pre-existing\n"
        let containerDir = tempDir.appendingPathComponent("containers").appendingPathComponent(containerId)
        let existingFormatter = try EXT4.Formatter(
            FilePath(rootfsPath.path),
            blockSize: 4096,
            minDiskSize: 10 * 1024 * 1024
        )
        let preExistingData = Data(preExistingContent.utf8)
        let stream = InputStream(data: preExistingData)
        stream.open()
        try existingFormatter.create(
            path: FilePath("/var/existing.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o644),
            buf: stream
        )
        stream.close()
        try existingFormatter.close()
        _ = containerDir  // silence unused warning

        let tarPath = try createSingleFileTar(content: "new\n", in: tempDir)

        try await service.putArchive(
            containerId: containerId,
            path: "/var/run/newdir",
            tarPath: tarPath,
            noOverwriteDirNonDir: false
        )

        #expect(try fileExists(rootfsPath: rootfsPath, path: "/var/existing.txt"))
        #expect(try readFile(rootfsPath: rootfsPath, path: "/var/existing.txt") == preExistingContent)
        #expect(try fileExists(rootfsPath: rootfsPath, path: "/var/run/newdir/hello.txt"))
    }

    @Test("putArchive throws rootfsNotFound when container has no rootfs")
    func putArchiveRootfsNotFound() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = ClientArchiveService(appSupportPath: tempDir)
        let tarPath = try createSingleFileTar(content: "x", in: tempDir)

        await #expect(throws: ClientArchiveError.self) {
            try await service.putArchive(
                containerId: "nonexistent-container",
                path: "/some/path",
                tarPath: tarPath,
                noOverwriteDirNonDir: false
            )
        }
    }

    @Test("putArchive with noOverwriteDirNonDir rejects overwriting a directory with a file")
    func putArchiveNoOverwriteDirNonDir() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerId = "c-\(UUID().uuidString)"
        let service = ClientArchiveService(appSupportPath: tempDir)
        let rootfsPath = try createRootfs(containerId: containerId, appSupportPath: tempDir)

        // First PUT: create /var/run/target as a directory
        let firstTar = try createSingleFileTar(content: "first\n", in: tempDir)
        try await service.putArchive(
            containerId: containerId,
            path: "/var/run/target",
            tarPath: firstTar,
            noOverwriteDirNonDir: false
        )
        #expect(try fileExists(rootfsPath: rootfsPath, path: "/var/run/target"))

        // Build a tar containing a plain file named "target" (not a directory)
        let stagingDir = tempDir.appendingPathComponent("staging-conflict-\(UUID().uuidString)")
        let conflictTar = tempDir.appendingPathComponent("conflict-\(UUID().uuidString).tar")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try "conflict".write(
            to: stagingDir.appendingPathComponent("target"),
            atomically: true,
            encoding: .utf8
        )
        try ArchiveUtility.create(tarPath: conflictTar, from: stagingDir)
        try? FileManager.default.removeItem(at: stagingDir)

        // Second PUT into /var/run with noOverwriteDirNonDir=true should fail
        await #expect(throws: Error.self) {
            try await service.putArchive(
                containerId: containerId,
                path: "/var/run",
                tarPath: conflictTar,
                noOverwriteDirNonDir: true
            )
        }
    }
}
