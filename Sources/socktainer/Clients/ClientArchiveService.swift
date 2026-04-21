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
    func putArchive(containerId: String, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws
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

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(containerId: String, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        let rootfsPath = getRootfsPath(containerId: containerId)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Pre-scan for dir/non-dir conflicts. Reader is scoped here and released
        // before EXT4Editor opens the same file, avoiding any exclusive-lock conflict.
        if noOverwriteDirNonDir {
            do {
                let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
                try validateArchiveEntries(reader: reader, tarPath: tarPath, destinationPath: normalizedPath)
            }
        }

        let editor = try EXT4Editor(devicePath: FilePath(rootfsPath.path))
        let archiveReader = try ArchiveReader(file: tarPath)

        for (entry, streamReader) in archiveReader.makeStreamingIterator() {
            guard let fullPath = ArchiveUtility.destinationPath(for: entry.path, under: normalizedPath) else {
                continue
            }

            switch entry.fileType {
            case .directory:
                if !editor.exists(path: fullPath) {
                    try ensureParentDirectories(of: fullPath, editor: editor)
                    try editor.createDirectory(
                        path: fullPath,
                        mode: UInt16(entry.permissions),
                        uid: entry.owner ?? 0,
                        gid: entry.group ?? 0
                    )
                }
            case .symbolicLink:
                try ensureParentDirectories(of: fullPath, editor: editor)
                try editor.addSymlink(
                    path: fullPath,
                    target: entry.symlinkTarget ?? "",
                    uid: entry.owner ?? 0,
                    gid: entry.group ?? 0
                )
            case .regular:
                try ensureParentDirectories(of: fullPath, editor: editor)
                var data = Data()
                var buf = Data(count: 65536)
                while true {
                    let n = buf.withUnsafeMutableBytes { raw -> Int in
                        guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                        return streamReader.read(ptr, maxLength: raw.count)
                    }
                    if n <= 0 { break }
                    data.append(buf.prefix(n))
                }
                try editor.addFile(
                    path: fullPath,
                    data: data,
                    mode: UInt16(entry.permissions),
                    uid: entry.owner ?? 0,
                    gid: entry.group ?? 0
                )
            default:
                continue
            }
        }

        try editor.sync()
    }

    private func ensureParentDirectories(of path: String, editor: EXT4Editor) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != "/" else { return }
        if editor.exists(path: parent) { return }
        try ensureParentDirectories(of: parent, editor: editor)
        try editor.createDirectory(path: parent)
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
        destinationPath: String
    ) throws {
        let archiveReader = try ArchiveReader(file: tarPath)

        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let fullPath = ArchiveUtility.destinationPath(for: entry.path, under: destinationPath) else {
                continue
            }

            guard reader.exists(FilePath(fullPath)) else {
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
