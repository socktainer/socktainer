import ContainerAPIClient
import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Vapor

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
    func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat) {
        let rootfsPath = getRootfsPath(containerId: containerId)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }

        // Normalize the path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Open the ext4 filesystem
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))

        // Check if path exists
        guard reader.exists(FilePath(normalizedPath)) else {
            throw ClientArchiveError.pathNotFound(path: normalizedPath)
        }

        // Create temporary files
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let fullExportPath = tempDir.appendingPathComponent("\(sessionId)-full.tar")
        let filteredTarPath = tempDir.appendingPathComponent("\(sessionId)-filtered.tar")

        defer {
            try? FileManager.default.removeItem(at: fullExportPath)
            try? FileManager.default.removeItem(at: filteredTarPath)
        }

        // Export the entire filesystem to a tar archive
        try reader.export(archive: FilePath(fullExportPath.path))

        // Filter the tar to only include the requested path
        let stat = try filterTarToPath(
            sourceTar: fullExportPath,
            destTar: filteredTarPath,
            requestedPath: normalizedPath
        )

        // Read the filtered tar data
        let tarData = try Data(contentsOf: filteredTarPath)

        return (tarData: tarData, stat: stat)
    }

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(containerId: String, path: String, tarData: Data, noOverwriteDirNonDir: Bool) async throws {
        let rootfsPath = getRootfsPath(containerId: containerId)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }

        // Normalize the destination path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

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
        try unpackTarToPath(formatter: formatter, tarPath: inputTarPath, destinationPath: normalizedPath)

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


    /// Filter a tar archive to only include entries matching the requested path
    private func filterTarToPath(sourceTar: URL, destTar: URL, requestedPath: String) throws -> PathStat {
        let sourceReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: sourceTar
        )

        let config = ArchiveWriterConfiguration(
            format: .paxRestricted,
            filter: .none,
            options: []
        )
        let writer = try ArchiveWriter(configuration: config)
        try writer.open(file: destTar)

        // Normalize the requested path for matching
        var matchPath = requestedPath
        if matchPath.hasPrefix("/") {
            matchPath = String(matchPath.dropFirst())
        }

        var foundStat: PathStat?
        var foundAnyEntry = false

        for (entry, streamReader) in sourceReader.makeStreamingIterator() {
            guard var entryPath = entry.path else {
                continue
            }

            // Normalize entry path
            if entryPath.hasPrefix("./") {
                entryPath = String(entryPath.dropFirst(2))
            }
            if entryPath.hasPrefix("/") {
                entryPath = String(entryPath.dropFirst())
            }

            // Check if this entry matches or is under the requested path
            let matches = entryPath == matchPath ||
                entryPath.hasPrefix(matchPath + "/") ||
                matchPath.isEmpty

            if matches {
                foundAnyEntry = true

                // Create stat for the exact match
                if entryPath == matchPath && foundStat == nil {
                    foundStat = PathStat(
                        name: (requestedPath as NSString).lastPathComponent,
                        size: entry.size ?? 0,
                        mode: UInt32(entry.permissions),
                        mtime: ISO8601DateFormatter().string(from: entry.modificationDate ?? Date()),
                        linkTarget: entry.symlinkTarget
                    )
                }

                // Calculate relative path from the requested path
                let relativePath: String
                if entryPath == matchPath {
                    relativePath = (requestedPath as NSString).lastPathComponent
                } else if matchPath.isEmpty {
                    relativePath = entryPath
                } else {
                    relativePath = String(entryPath.dropFirst(matchPath.count + 1))
                }

                // Write the entry with the relative path
                let newEntry = WriteEntry()
                newEntry.path = relativePath
                newEntry.permissions = entry.permissions
                newEntry.owner = entry.owner
                newEntry.group = entry.group
                newEntry.modificationDate = entry.modificationDate
                newEntry.contentAccessDate = entry.contentAccessDate
                newEntry.creationDate = entry.creationDate
                newEntry.xattrs = entry.xattrs
                newEntry.fileType = entry.fileType

                if entry.fileType == .symbolicLink {
                    newEntry.symlinkTarget = entry.symlinkTarget
                    try writer.writeEntry(entry: newEntry, data: nil)
                } else if entry.fileType == .directory {
                    try writer.writeEntry(entry: newEntry, data: nil)
                } else if entry.fileType == .regular {
                    newEntry.size = entry.size ?? 0
                    // Read the file data
                    var data = Data()
                    let bufferSize = 64 * 1024
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                    defer { buffer.deallocate() }

                    while true {
                        let bytesRead = streamReader.read(buffer, maxLength: bufferSize)
                        if bytesRead <= 0 {
                            break
                        }
                        data.append(buffer, count: bytesRead)
                    }
                    try writer.writeEntry(entry: newEntry, data: data)
                } else if let hardlink = entry.hardlink {
                    newEntry.hardlink = hardlink
                    try writer.writeEntry(entry: newEntry, data: nil)
                }
            }
        }

        try writer.finishEncoding()

        if !foundAnyEntry {
            throw ClientArchiveError.pathNotFound(path: requestedPath)
        }

        // If we didn't find an exact match stat, create one for the directory
        if foundStat == nil {
            foundStat = PathStat(
                name: (requestedPath as NSString).lastPathComponent,
                size: 0,
                mode: 0o755 | 0x4000,  // Directory mode
                mtime: ISO8601DateFormatter().string(from: Date()),
                linkTarget: nil
            )
        }

        return foundStat!
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
