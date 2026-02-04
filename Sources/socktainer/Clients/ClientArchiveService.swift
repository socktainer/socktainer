import ContainerAPIClient
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
    func putArchive(containerId: String, path: String, tarData: Data, noOverwriteDirNonDir: Bool) async throws
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
        try TarUtility.create(tarPath: tarPath, from: stagingDir)

        // Read the tar data
        let tarData = try Data(contentsOf: tarPath)

        return (tarData: tarData, stat: pathStat)
    }

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(containerId: String, path: String, tarData: Data, noOverwriteDirNonDir: Bool) async throws {
        let rootfsPath = getRootfsPath(containerId: containerId)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }

        // Normalize the destination path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Try optimized in-place modification first
        // This is O(tar size) instead of O(filesystem size)
        if let success = try? await putArchiveOptimized(
            rootfsPath: rootfsPath,
            destinationPath: normalizedPath,
            tarData: tarData
        ), success {
            return
        }

        // Fall back to full read-modify-write approach
        try await putArchiveFallback(
            rootfsPath: rootfsPath,
            destinationPath: normalizedPath,
            tarData: tarData
        )
    }

    /// Optimized PUT using EXT4Editor for in-place modification
    /// Returns true if successful, false if fallback is needed
    private func putArchiveOptimized(
        rootfsPath: URL,
        destinationPath: String,
        tarData: Data
    ) async throws -> Bool {
        // Extract tar to temp directory first to examine contents
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let extractDir = tempDir.appendingPathComponent("\(sessionId)-extract")

        defer {
            try? FileManager.default.removeItem(at: extractDir)
        }

        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Write tar and extract it
        let tarPath = tempDir.appendingPathComponent("\(sessionId).tar")
        defer { try? FileManager.default.removeItem(at: tarPath) }
        try tarData.write(to: tarPath)

        // Extract tar to temp directory
        try TarUtility.extract(tarPath: tarPath, to: extractDir)

        // Open EXT4Editor
        let editor = try EXT4Editor(devicePath: FilePath(rootfsPath.path))

        // Process extracted files
        let success = try processExtractedFiles(
            editor: editor,
            extractDir: extractDir,
            basePath: extractDir.path,
            destinationPath: destinationPath
        )

        if success {
            try editor.sync()
        }

        return success
    }

    /// Recursively process extracted files and add them to the filesystem
    private func processExtractedFiles(
        editor: EXT4Editor,
        extractDir: URL,
        basePath: String,
        destinationPath: String
    ) throws -> Bool {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        )

        for itemURL in contents {
            let relativePath = String(itemURL.path.dropFirst(basePath.count))
            let fullDestPath =
                destinationPath == "/"
                ? relativePath
                : destinationPath + relativePath

            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = resourceValues.isDirectory ?? false
            let isSymlink = resourceValues.isSymbolicLink ?? false

            if isSymlink {
                // Handle symlink
                let target = try fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
                if editor.exists(path: fullDestPath) {
                    // Can't overwrite with EXT4Editor, fall back
                    return false
                }
                try editor.addSymlink(path: fullDestPath, target: target)
            } else if isDirectory {
                // Handle directory
                if !editor.exists(path: fullDestPath) {
                    try editor.createDirectory(path: fullDestPath)
                }
                // Recursively process contents
                let success = try processExtractedFiles(
                    editor: editor,
                    extractDir: itemURL,
                    basePath: basePath,
                    destinationPath: destinationPath
                )
                if !success {
                    return false
                }
            } else {
                // Handle regular file
                if editor.exists(path: fullDestPath) {
                    // Can't overwrite with EXT4Editor, fall back
                    return false
                }

                let fileData = try Data(contentsOf: itemURL)
                let attributes = try fileManager.attributesOfItem(atPath: itemURL.path)
                let posixPermissions = (attributes[.posixPermissions] as? UInt16) ?? 0o644

                try editor.addFile(
                    path: fullDestPath,
                    data: fileData,
                    mode: posixPermissions
                )
            }
        }

        return true
    }

    /// Fallback PUT using full read-modify-write approach
    private func putArchiveFallback(
        rootfsPath: URL,
        destinationPath: String,
        tarData: Data
    ) async throws {
        // Create temporary files for the operation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let exportedTarPath = tempDir.appendingPathComponent("\(sessionId)-export.tar")
        let inputTarPath = tempDir.appendingPathComponent("\(sessionId)-input.tar")
        let newRootfsPath = tempDir.appendingPathComponent("\(sessionId)-rootfs.ext4")

        defer {
            try? FileManager.default.removeItem(at: exportedTarPath)
            try? FileManager.default.removeItem(at: inputTarPath)
            try? FileManager.default.removeItem(at: newRootfsPath)
        }

        // Write the input tar data to a temporary file
        try tarData.write(to: inputTarPath)

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
        try formatter.unpack(reader: existingReader)

        // Step 5: Unpack the new tar at the specified destination path
        try unpackTarToPath(formatter: formatter, tarPath: inputTarPath, destinationPath: destinationPath)

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

    /// Extract a path from the ext4 filesystem to a local directory
    private func extractPathToDirectory(reader: EXT4.EXT4Reader, sourcePath: String, destDir: URL) throws {
        let (_, inode) = try reader.stat(FilePath(sourcePath))
        let baseName = (sourcePath as NSString).lastPathComponent

        if inode.isDirectory {
            // Create the directory
            let dirDest = destDir.appendingPathComponent(baseName)
            try FileManager.default.createDirectory(at: dirDest, withIntermediateDirectories: true)

            // Set permissions
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: inode.permissions)],
                ofItemAtPath: dirDest.path
            )

            // Recursively extract contents
            let entries = try reader.listDirectory(FilePath(sourcePath))
            for entry in entries {
                let childPath = sourcePath == "/" ? "/\(entry)" : "\(sourcePath)/\(entry)"
                try extractPathToDirectory(reader: reader, sourcePath: childPath, destDir: dirDest)
            }
        } else if inode.isRegularFile {
            // Read file contents
            let fileData = try reader.readFile(at: FilePath(sourcePath))
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
                let linkDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createSymbolicLink(atPath: linkDest.path, withDestinationPath: target)
            }
        }
        // Skip other file types (devices, fifos, sockets)
    }

    private func unpackTarToPath(formatter: EXT4.Formatter, tarPath: URL, destinationPath: String) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        // Reusable buffer for file content
        let bufferSize = 128 * 1024
        let reusableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
        defer { reusableBuffer.deallocate() }

        for (entry, streamReader) in archiveReader.makeStreamingIterator() {
            guard var entryPath = entry.path else {
                continue
            }

            // Normalize the entry path
            if entryPath.hasPrefix("./") {
                entryPath = String(entryPath.dropFirst(1))
            }
            if !entryPath.hasPrefix("/") {
                entryPath = "/" + entryPath
            }

            // Construct the full destination path
            let fullPath: String
            if destinationPath == "/" {
                fullPath = entryPath
            } else {
                fullPath = destinationPath + entryPath
            }

            let filePath = FilePath(fullPath)
            let ts = FileTimestamps(
                access: entry.contentAccessDate,
                modification: entry.modificationDate,
                creation: entry.creationDate
            )

            switch entry.fileType {
            case .directory:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFDIR, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            case .regular:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFREG, entry.permissions),
                    ts: ts,
                    buf: streamReader,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs,
                    fileBuffer: reusableBuffer
                )
            case .symbolicLink:
                var symlinkTarget: FilePath?
                if let target = entry.symlinkTarget {
                    symlinkTarget = FilePath(target)
                }
                try formatter.create(
                    path: filePath,
                    link: symlinkTarget,
                    mode: EXT4.Inode.Mode(.S_IFLNK, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            default:
                continue
            }
        }
    }
}
