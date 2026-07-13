import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Vapor

/// Extension to add convenience computed properties for EXT4.Inode
extension EXT4.Inode {
    /// Full 64-bit file size
    var size: Int64 {
        Int64(sizeLow) | (Int64(sizeHigh) << 32)
    }

    /// Full 32-bit user ID
    var fullUid: UInt32 {
        UInt32(uid) | (UInt32(uidHigh) << 16)
    }

    /// Full 32-bit group ID
    var fullGid: UInt32 {
        UInt32(gid) | (UInt32(gidHigh) << 16)
    }

    /// Check if this is a directory
    var isDirectory: Bool {
        (mode & 0xF000) == 0x4000
    }

    /// Check if this is a regular file
    var isRegularFile: Bool {
        (mode & 0xF000) == 0x8000
    }

    /// Check if this is a symbolic link
    var isSymlink: Bool {
        (mode & 0xF000) == 0xA000
    }

    /// Permission bits only (without file type)
    var permissions: UInt16 {
        mode & 0x0FFF
    }
}

/// Errors specific to archive operations
enum ClientArchiveError: Error, LocalizedError {
    case containerNotFound(id: String)
    case pathNotFound(path: String)
    case rootfsNotFound(id: String)
    case invalidPath(path: String)
    case notADirectory(path: String)
    case operationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .containerNotFound(let id):
            return "Container not found: \(id)"
        case .pathNotFound(let path):
            return "Path not found in container: \(path)"
        case .rootfsNotFound(let id):
            return "Rootfs not found for container: \(id)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .notADirectory(let path):
            return "Extraction point is not a directory: \(path)"
        case .operationFailed(let message):
            return "Archive operation failed: \(message)"
        }
    }
}

/// File stat information for the X-Docker-Container-Path-Stat header
struct PathStat: Codable {
    let name: String
    let size: Int64
    let mode: UInt32
    let mtime: String
    let linkTarget: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case mode
        case mtime
        case linkTarget
    }
}

/// Protocol for archive operations on containers
protocol ClientArchiveProtocol: Sendable {
    /// Get the path to a container's rootfs
    func getRootfsPath(containerId: String) -> URL

    /// Read a file or directory from a container's filesystem and return as tar data
    func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat)

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws

    /// Export the container's entire root filesystem as an uncompressed tar
    /// (docker export). The caller owns the returned file and deletes it when done.
    func exportRootfs(containerId: String) async throws -> URL
}

/// Service for performing archive operations on container filesystems
struct ClientArchiveService: ClientArchiveProtocol {
    private let appSupportPath: URL

    init(appSupportPath: URL) {
        self.appSupportPath = appSupportPath
    }

    /// Get the path to a container's rootfs.ext4 file
    func getRootfsPath(containerId: String) -> URL {
        appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
            .appendingPathComponent("rootfs.ext4")
    }

    /// Read a file or directory from a container's filesystem and return as tar data
    /// This implementation reads only the requested path directly, avoiding full filesystem export.
    func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat) {
        let rootfsPath = getRootfsPath(containerId: containerId)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }

        // Normalize the path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Open the ext4 filesystem
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))

        // Check if path exists and get stat
        guard reader.exists(FilePath(normalizedPath)) else {
            throw ClientArchiveError.pathNotFound(path: normalizedPath)
        }

        let (_, inode) = try reader.stat(FilePath(normalizedPath))

        // Create PathStat for the response header
        let pathStat = PathStat(
            name: (normalizedPath as NSString).lastPathComponent,
            size: inode.size,
            mode: UInt32(inode.mode),
            mtime: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(inode.mtime))),
            linkTarget: inode.isSymlink ? readSymlinkTarget(reader: reader, path: normalizedPath) : nil
        )

        // Create temporary directory for tar creation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let stagingDir = tempDir.appendingPathComponent("\(sessionId)-staging")
        let tarPath = tempDir.appendingPathComponent("\(sessionId).tar")

        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: tarPath)
        }

        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Extract the requested path to the staging directory
        try extractPathToDirectory(reader: reader, sourcePath: normalizedPath, destDir: stagingDir)

        // Create tar archive from the staging directory
        try ArchiveUtility.create(tarPath: tarPath, from: stagingDir)

        // Read the tar data
        let tarData = try Data(contentsOf: tarPath)

        return (tarData: tarData, stat: pathStat)
    }

    /// Reading rootfs.ext4 while the guest VM writes to it is a volatile
    /// snapshot — the same guarantee moby gives when exporting a running
    /// container's mounted layer. The export runs detached because it is
    /// synchronous I/O that can take minutes for large filesystems.
    func exportRootfs(containerId: String) async throws -> URL {
        let rootfsPath = getRootfsPath(containerId: containerId)
        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }
        let tarPath = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).tar")
        let blockDevicePath = rootfsPath.path
        let archivePath = tarPath.path
        do {
            try await Task.detached(priority: .utility) {
                let reader = try EXT4.EXT4Reader(blockDevice: FilePath(blockDevicePath))
                try reader.export(archive: FilePath(archivePath))
            }.value
        } catch {
            try? FileManager.default.removeItem(at: tarPath)
            throw ClientArchiveError.operationFailed(message: "failed to read rootfs of \(containerId): \(error)")
        }
        return tarPath
    }

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        // Normalize the destination path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // A running container's VM holds rootfs.ext4 open as its block device:
        // rewriting and swapping the file on the host is never seen by the guest
        // (and guest writes would diverge from the swapped file). Inject through
        // the live container instead.
        if container.status == .running {
            try await putArchiveViaCopyIn(
                container: container,
                destinationPath: normalizedPath,
                tarPath: tarPath,
                noOverwriteDirNonDir: noOverwriteDirNonDir
            )
            return
        }

        let rootfsPath = getRootfsPath(containerId: container.id)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try validateArchiveEntries(
            reader: reader,
            tarPath: tarPath,
            destinationPath: normalizedPath,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        try await putArchiveFallback(
            rootfsPath: rootfsPath,
            destinationPath: normalizedPath,
            inputTarPath: tarPath
        )
    }

    /// One parsed entry of the uploaded archive.
    private struct ArchiveEntryPlan {
        enum Kind {
            case directory
            case file
            case symlink(target: String)
        }
        let relativePath: String
        let guestPath: String
        let kind: Kind
        let mode: UInt32
    }

    /// Inject the archive into a RUNNING container.
    ///
    /// Docker semantics require extracting *into* the destination without
    /// disturbing what already exists (e.g. a tar entry `tmp/foo` must not
    /// change the ownership/mode/sticky bit of an existing `/tmp`). So instead
    /// of pushing whole directories through copyIn (whose in-guest extraction
    /// applies archived directory metadata over existing directories), this:
    ///  1. runs ONE `/bin/sh` exec in the guest that validates the destination
    ///     (404/400/conflict semantics that copyIn cannot express) and creates
    ///     missing directories and symlinks (`mkdir` skips existing dirs), then
    ///  2. streams each regular file individually over vsock via the daemon's
    ///     copyIn API with the mode recorded in the tar.
    private func putArchiveViaCopyIn(
        container: ContainerSnapshot,
        destinationPath: String,
        tarPath: URL,
        noOverwriteDirNonDir: Bool
    ) async throws {
        let plan = try parseArchiveEntries(tarPath: tarPath, destinationPath: destinationPath)

        try await prepareGuestForCopy(
            container: container,
            destinationPath: destinationPath,
            entries: plan,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        let files = plan.filter {
            if case .file = $0.kind { return true }
            return false
        }
        guard !files.isEmpty else { return }

        // Unpack the uploaded tar to a staging directory for the file contents
        // (modes are taken from the tar entries, not the staged files).
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("put-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        try ArchiveUtility.extract(tarPath: tarPath, to: stagingDir)

        let client = ContainerClient()
        for file in files {
            let stagedURL = stagingDir.appendingPathComponent(file.relativePath)
            guard FileManager.default.fileExists(atPath: stagedURL.path) else {
                throw ClientArchiveError.operationFailed(message: "archive entry missing after extraction: \(file.relativePath)")
            }
            do {
                try await client.copyIn(
                    id: container.id,
                    source: stagedURL.path,
                    destination: file.guestPath,
                    mode: file.mode
                )
            } catch {
                throw ClientArchiveError.operationFailed(
                    message: "Failed to copy \(file.relativePath) into running container: \(error.localizedDescription)")
            }
        }
    }

    /// Parse the uploaded tar into a copy plan.
    private func parseArchiveEntries(tarPath: URL, destinationPath: String) throws -> [ArchiveEntryPlan] {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        var plan: [ArchiveEntryPlan] = []
        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let entryPath = entry.path,
                let guestPath = ArchiveUtility.destinationPath(for: entryPath, under: destinationPath),
                guestPath != destinationPath
            else {
                continue
            }

            var relativePath = entryPath
            if relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }

            let mode = UInt32(entry.permissions) & 0o7777
            switch entry.fileType {
            case .directory:
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .directory, mode: mode))
            case .regular:
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .file, mode: mode))
            case .symbolicLink:
                guard let target = entry.symlinkTarget else { continue }
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .symlink(target: target), mode: mode))
            default:
                throw ClientArchiveError.operationFailed(
                    message: "unsupported archive entry type for copy into a running container: \(relativePath)")
            }
        }
        return plan
    }

    /// Run Docker's PUT-archive validation inside the running guest and create
    /// the directory/symlink structure for the incoming archive: destination
    /// must exist (404) and be a directory (400), optional per-entry
    /// noOverwriteDirNonDir conflict checks, `mkdir` for missing directories
    /// (existing ones are left untouched), and `ln -sfn` for symlinks.
    private func prepareGuestForCopy(
        container: ContainerSnapshot,
        destinationPath: String,
        entries: [ArchiveEntryPlan],
        noOverwriteDirNonDir: Bool
    ) async throws {
        let script = buildPreparationScript(
            entries: entries,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        var processConfig = container.configuration.initProcess
        processConfig.executable = "/bin/sh"
        processConfig.arguments = ["-c", script, "sh", destinationPath]
        processConfig.terminal = false
        // Validate as root so restrictive permissions on parent directories
        // cannot mask the existence checks.
        processConfig.user = .id(uid: 0, gid: 0)

        guard let pipes = StdioPipes.make([.stderr]) else {
            throw ClientArchiveError.operationFailed(message: "Failed to create stderr pipe")
        }

        let process: ClientProcess
        do {
            process = try await ContainerClient().createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfig,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw ClientArchiveError.operationFailed(message: "Failed to exec into running container: \(error.localizedDescription)")
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw ClientArchiveError.operationFailed(message: "Failed to exec into running container: \(error.localizedDescription)")
        }

        // Drain stderr concurrently (capped at 16 KiB) while waiting.
        // collectOutput() is not used here because it reads unboundedly via
        // readDataToEndOfFile(); this capped reader prevents runaway memory growth.
        let stderrReader = pipes.stderr!.read
        let stderrTask = Task.detached { () -> Data in
            defer { try? stderrReader.close() }
            var collected = Data()
            while let chunk = try? stderrReader.read(upToCount: 4096), !chunk.isEmpty {
                if collected.count < 16 * 1024 {
                    collected.append(chunk)
                }
            }
            return collected
        }

        let exitCode: Int32
        do {
            exitCode = try await process.wait()
        } catch {
            // Concurrent close(2) + read(2) on the same fd is unsafe (NSException risk).
            // Rethrow immediately; stderrTask exits naturally when the process terminates
            // and Apple closes the write end.
            throw ClientArchiveError.operationFailed(message: "Failed waiting for validation in running container: \(error.localizedDescription)")
        }

        let stderrText =
            String(data: await stderrTask.value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch exitCode {
        case 0:
            return
        case 40:
            throw ClientArchiveError.pathNotFound(path: destinationPath)
        case 41:
            throw ClientArchiveError.notADirectory(path: destinationPath)
        default:
            let detail = stderrText.isEmpty ? "" : ": \(stderrText)"
            throw ClientArchiveError.operationFailed(message: "Validation in running container failed (exit \(exitCode))\(detail)")
        }
    }

    /// Build the validation/preparation shell script run inside the guest.
    /// Only `sh`, `mkdir`, `ln` and `test` are required. Existing directories
    /// are never modified, mirroring how tar treats implicit parents.
    private func buildPreparationScript(
        entries: [ArchiveEntryPlan],
        noOverwriteDirNonDir: Bool
    ) -> String {
        var lines = [
            "set -u",
            "dest=\"$1\"",
            "if [ ! -e \"$dest\" ]; then echo \"destination does not exist: $dest\" >&2; exit 40; fi",
            "if [ ! -d \"$dest\" ]; then echo \"extraction point is not a directory: $dest\" >&2; exit 41; fi",
        ]

        if noOverwriteDirNonDir {
            for entry in entries {
                let quoted = shellSingleQuoted(entry.guestPath)
                if case .directory = entry.kind {
                    lines.append("if [ -e \(quoted) ] && [ ! -d \(quoted) ]; then echo \"refusing to overwrite non-directory with directory\" >&2; exit 43; fi")
                } else {
                    lines.append("if [ -d \(quoted) ]; then echo \"refusing to overwrite directory with non-directory\" >&2; exit 43; fi")
                }
            }
        }

        // Explicit directory entries: create missing ones with the archived
        // mode (parents first); never touch directories that already exist.
        let directories =
            entries
            .compactMap { entry -> (path: String, mode: UInt32)? in
                guard case .directory = entry.kind else { return nil }
                return (entry.guestPath, entry.mode)
            }
            .sorted { $0.path.count < $1.path.count }
        for directory in directories {
            let quoted = shellSingleQuoted(directory.path)
            let parent = shellSingleQuoted((directory.path as NSString).deletingLastPathComponent)
            let octal = String(directory.mode, radix: 8)
            lines.append(
                "if [ ! -d \(quoted) ]; then mkdir -p \(parent) && mkdir -m \(octal) \(quoted) || { echo \"failed to create directory \(directory.path)\" >&2; exit 44; }; fi")
        }

        // Implicit parents of file/symlink entries (mkdir -p is a no-op on
        // existing directories).
        var parents = Set<String>()
        for entry in entries {
            if case .directory = entry.kind { continue }
            let parent = (entry.guestPath as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != "/" {
                parents.insert(parent)
            }
        }
        for parent in parents.sorted() {
            lines.append("mkdir -p \(shellSingleQuoted(parent)) || { echo \"failed to create parent directory \(parent)\" >&2; exit 44; }")
        }

        for entry in entries {
            guard case .symlink(let target) = entry.kind else { continue }
            lines.append(
                "ln -sfn \(shellSingleQuoted(target)) \(shellSingleQuoted(entry.guestPath)) || { echo \"failed to create symlink \(entry.guestPath)\" >&2; exit 45; }")
        }

        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fallback PUT using full read-modify-write approach
    private func putArchiveFallback(
        rootfsPath: URL,
        destinationPath: String,
        inputTarPath: URL
    ) async throws {
        // Create temporary files for the operation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let exportedTarPath = tempDir.appendingPathComponent("\(sessionId)-export.tar")
        let newRootfsPath = tempDir.appendingPathComponent("\(sessionId)-rootfs.ext4")

        defer {
            try? FileManager.default.removeItem(at: exportedTarPath)
            try? FileManager.default.removeItem(at: newRootfsPath)
        }

        // Step 1: Export existing filesystem to tar
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try reader.export(archive: FilePath(exportedTarPath.path))

        // Step 2: Get the size of the existing rootfs to create a new one of similar size
        let rootfsAttributes = try FileManager.default.attributesOfItem(atPath: rootfsPath.path)
        let rootfsSize = (rootfsAttributes[.size] as? UInt64) ?? (2 * 1024 * 1024 * 1024)  // Default 2GB

        // Step 3: Create a new ext4 formatter
        // Use a minimum size that can accommodate the filesystem
        let minSize = max(rootfsSize, 256 * 1024)  // At least 256KB
        let formatter = try EXT4.Formatter(
            FilePath(newRootfsPath.path),
            blockSize: 4096,
            minDiskSize: minSize
        )

        // Step 4: Unpack the existing filesystem
        let existingReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: exportedTarPath
        )
        try await formatter.unpack(reader: existingReader)

        // Step 5: Unpack the new tar at the specified destination path
        try ArchiveUtility.unpack(
            tarPath: inputTarPath,
            to: formatter,
            destinationPath: destinationPath
        )

        // Step 6: Finalize the new filesystem
        try formatter.close()

        // Step 7: Atomically replace the old rootfs with the new one
        let backupPath = rootfsPath.appendingPathExtension("backup")
        try? FileManager.default.removeItem(at: backupPath)

        // Move old rootfs to backup
        try FileManager.default.moveItem(at: rootfsPath, to: backupPath)

        do {
            // Move new rootfs into place
            try FileManager.default.moveItem(at: newRootfsPath, to: rootfsPath)
            // Remove backup on success
            try? FileManager.default.removeItem(at: backupPath)
        } catch {
            // Restore backup on failure
            try? FileManager.default.moveItem(at: backupPath, to: rootfsPath)
            throw ClientArchiveError.operationFailed(message: "Failed to replace rootfs: \(error.localizedDescription)")
        }
    }

    /// Read symlink target using the reader's public API
    private func readSymlinkTarget(reader: EXT4.EXT4Reader, path: String) -> String? {
        guard let data = try? reader.readFile(at: FilePath(path), followSymlinks: false) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func validateArchiveEntries(
        reader: EXT4.EXT4Reader,
        tarPath: URL,
        destinationPath: String,
        noOverwriteDirNonDir: Bool
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let fullPath = ArchiveUtility.destinationPath(for: entry.path, under: destinationPath) else {
                continue
            }

            guard noOverwriteDirNonDir, reader.exists(FilePath(fullPath)) else {
                continue
            }

            let (_, inode) = try reader.stat(FilePath(fullPath))
            let existingIsDirectory = inode.isDirectory
            let incomingIsDirectory = entry.fileType == .directory

            if existingIsDirectory != incomingIsDirectory {
                throw ClientArchiveError.operationFailed(
                    message: "Refusing to overwrite \(existingIsDirectory ? "directory" : "non-directory") at \(fullPath)"
                )
            }
        }
    }

    /// Extract a path from the ext4 filesystem to a local directory
    private func extractPathToDirectory(reader: EXT4.EXT4Reader, sourcePath: String, destDir: URL) throws {
        let (_, inode) = try reader.stat(FilePath(sourcePath))
        let baseName = sourcePath == "/" ? nil : (sourcePath as NSString).lastPathComponent

        if inode.isDirectory {
            let dirDest: URL
            if let baseName {
                dirDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createDirectory(at: dirDest, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: inode.permissions)],
                    ofItemAtPath: dirDest.path
                )
            } else {
                dirDest = destDir
            }

            // Recursively extract contents
            let entries = try reader.listDirectory(FilePath(sourcePath))
            for entry in entries {
                let childPath = sourcePath == "/" ? "/\(entry)" : "\(sourcePath)/\(entry)"
                try extractPathToDirectory(reader: reader, sourcePath: childPath, destDir: dirDest)
            }
        } else if inode.isRegularFile {
            // Read file contents
            let fileData = try reader.readFile(at: FilePath(sourcePath))
            guard let baseName else {
                throw ClientArchiveError.invalidPath(path: sourcePath)
            }
            let fileDest = destDir.appendingPathComponent(baseName)

            // Write file
            try fileData.write(to: fileDest)

            // Set permissions and modification time
            let mtimeDate = Date(timeIntervalSince1970: TimeInterval(inode.mtime))
            try FileManager.default.setAttributes(
                [
                    .posixPermissions: NSNumber(value: inode.permissions),
                    .modificationDate: mtimeDate,
                ],
                ofItemAtPath: fileDest.path
            )
        } else if inode.isSymlink {
            // Read symlink target
            if let target = readSymlinkTarget(reader: reader, path: sourcePath) {
                guard let baseName else {
                    throw ClientArchiveError.invalidPath(path: sourcePath)
                }
                let linkDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createSymbolicLink(atPath: linkDest.path, withDestinationPath: target)
            }
        }
        // Skip other file types (devices, fifos, sockets)
    }

}
