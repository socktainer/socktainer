import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

/// Docker's copy-up: a named volume mounted over a path that exists in the image
/// starts out holding that path's contents, ownership and permissions, so an
/// image shipping a data directory owned by a non-root user can write to it.
///
/// A freshly formatted EXT4 volume is empty, root-owned and carries `/lost+found`
/// instead, which is why an image like Postgres cannot initialise its own data
/// directory on a new volume.
enum VolumeCopyUp {
    /// True when the volume holds nothing but what a freshly formatted EXT4 image
    /// always carries. Copy-up applies to empty volumes only: Docker leaves a
    /// volume that already has contents alone.
    static func isEmpty(volumeImagePath: String) -> Bool {
        guard let reader = try? EXT4.EXT4Reader(blockDevice: FilePath(volumeImagePath)),
            let entries = try? reader.listDirectory(FilePath("/"))
        else {
            return false
        }
        return entries.allSatisfy { $0 == "." || $0 == ".." || $0 == "lost+found" }
    }

    /// Where the image's filesystem lives for a container that has been created
    /// but never started. Apple Container writes the reference at create time;
    /// until the container runs there is no per-container rootfs to read.
    static func imageFilesystem(containerId: String, appSupportPath: URL) -> URL? {
        struct RuntimeConfiguration: Decodable {
            struct Filesystem: Decodable { let source: String }
            let containerRootFilesystem: Filesystem
        }
        let configURL =
            appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
            .appendingPathComponent("runtime-configuration.json")
        guard let data = try? Data(contentsOf: configURL),
            let config = try? JSONDecoder().decode(RuntimeConfiguration.self, from: data),
            !config.containerRootFilesystem.source.isEmpty
        else {
            return nil
        }
        let source = URL(fileURLWithPath: config.containerRootFilesystem.source)
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// Rebuilds the volume image so its root carries what the image holds at
    /// `sourcePath`. Runs even when the image has nothing there, because the
    /// rebuild is also what drops `/lost+found` — a Docker volume never has one,
    /// and Postgres refuses a data directory that does.
    static func populate(
        volumeImagePath: String,
        fromRootfs rootfsPath: String,
        sourcePath: String,
        logger: Logger
    ) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath))
        let source = FilePath(sourcePath.hasPrefix("/") ? sourcePath : "/\(sourcePath)")

        var rootInode: EXT4.Inode?
        if reader.exists(source, followSymlinks: true) {
            let (_, inode) = try reader.stat(source)
            if inode.isDirectory { rootInode = inode }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: volumeImagePath)
        let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let destination = URL(fileURLWithPath: volumeImagePath)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("copyup-\(UUID().uuidString).img")

        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: staging) } }

        let formatter = try EXT4.Formatter(
            FilePath(staging.path),
            blockSize: 4096,
            minDiskSize: max(currentSize, 4 * 1024 * 1024)
        )
        if let rootInode {
            // The mount root carries ownership of its own: a directory the image
            // hands to a non-root user is unusable if only its children are copied.
            try formatter.create(
                path: FilePath("/"),
                mode: rootInode.mode,
                ts: timestamps(of: rootInode),
                uid: rootInode.fullUid,
                gid: rootInode.fullGid
            )
            var linkedInodes: [EXT4.InodeNumber: FilePath] = [:]
            try copyChildren(
                of: source, from: reader, into: formatter,
                at: FilePath("/"), linked: &linkedInodes, logger: logger)
        }
        try formatter.unlink(path: FilePath("/lost+found"))
        try formatter.close()

        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        completed = true
    }

    private static func copyChildren(
        of source: FilePath,
        from reader: EXT4.EXT4Reader,
        into formatter: EXT4.Formatter,
        at target: FilePath,
        linked: inout [EXT4.InodeNumber: FilePath],
        logger: Logger
    ) throws {
        for name in try reader.listDirectory(source) where name != "." && name != ".." {
            let child = source.join(name)
            let childTarget = target.join(name)
            let (inodeNumber, inode) = try reader.stat(child, followSymlinks: false)

            // A second name for an inode already written is a hard link, not a copy.
            if !inode.isDirectory, inode.linksCount > 1, let first = linked[inodeNumber] {
                try formatter.link(link: childTarget, target: first)
                continue
            }

            if inode.isDirectory {
                try formatter.create(
                    path: childTarget, mode: inode.mode, ts: timestamps(of: inode),
                    uid: inode.fullUid, gid: inode.fullGid)
                try copyChildren(
                    of: child, from: reader, into: formatter,
                    at: childTarget, linked: &linked, logger: logger)
            } else if inode.isSymlink {
                guard let link = symlinkTarget(of: inode, at: child, from: reader) else {
                    logger.warning("[volume-copyup] unreadable symlink skipped: \(child)")
                    continue
                }
                try formatter.create(
                    path: childTarget, link: FilePath(link), mode: inode.mode,
                    ts: timestamps(of: inode), uid: inode.fullUid, gid: inode.fullGid)
            } else if inode.isRegularFile {
                let contents = EXT4FileStream(reader: reader, path: child, size: UInt64(inode.size))
                try formatter.create(
                    path: childTarget, mode: inode.mode, ts: timestamps(of: inode),
                    buf: contents, uid: inode.fullUid, gid: inode.fullGid)
            } else {
                // Device nodes, FIFOs and sockets carry a device number the
                // formatter has no way to set, so they are reported rather than
                // written as something they are not.
                logger.warning("[volume-copyup] unsupported file type not copied: \(child)")
                continue
            }
            if inode.linksCount > 1 { linked[inodeNumber] = childTarget }
        }
    }

    /// A short target is stored in the inode's block array rather than in a data
    /// block, and only the longer form can be read back as file contents.
    private static func symlinkTarget(
        of inode: EXT4.Inode, at path: FilePath, from reader: EXT4.EXT4Reader
    ) -> String? {
        if inode.size < 60 {
            var block = inode.block
            let bytes = withUnsafeBytes(of: &block) { Array($0.prefix(Int(inode.size))) }
            return String(bytes: bytes, encoding: .utf8)
        }
        guard let data = try? reader.readFile(at: path, followSymlinks: false) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func timestamps(of inode: EXT4.Inode) -> FileTimestamps {
        // ext4 keeps creation time in crtime; ctime is the inode's own change
        // time and would be the wrong answer here. An image that never recorded
        // one leaves it at zero, where the formatter's default is better.
        FileTimestamps(
            access: Date(timeIntervalSince1970: TimeInterval(inode.atime)),
            modification: Date(timeIntervalSince1970: TimeInterval(inode.mtime)),
            creation: inode.crtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(inode.crtime))
        )
    }
}

/// Streams a file out of an EXT4 image so a copy never holds the whole file in
/// memory — an image's data directory can carry files of any size.
private final class EXT4FileStream: ReadableStream {
    private let reader: EXT4.EXT4Reader
    private let path: FilePath
    private let size: UInt64
    private var offset: UInt64 = 0

    init(reader: EXT4.EXT4Reader, path: FilePath, size: UInt64) {
        self.reader = reader
        self.path = path
        self.size = size
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        guard offset < size, maxLength > 0 else { return 0 }
        let want = min(UInt64(maxLength), size - offset)
        let raw = UnsafeMutableRawBufferPointer(start: buffer, count: Int(want))
        do {
            let read = try reader.readFile(at: path, into: raw, offset: offset, followSymlinks: false)
            offset += UInt64(read)
            return read
        } catch {
            return -1
        }
    }
}
