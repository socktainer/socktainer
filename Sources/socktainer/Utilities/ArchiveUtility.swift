import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage

enum ArchiveUtilityError: Error {
    case invalidPath
    case archiveCreationFailed(String)
    case archiveReadFailed(String)
    case archiveWriteFailed(String)
    case entryReadFailed(String)
    case rejectedArchiveEntries([String])
}

struct ArchiveUtility {

    static func extract(tarPath: URL, to destination: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: tarPath.path) else {
            throw ArchiveUtilityError.invalidPath
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let archiveReader: ArchiveReader
        do {
            archiveReader = try ArchiveReader(file: tarPath)
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }

        do {
            let rejectedPaths = try archiveReader.extractContents(to: destination)
            if !rejectedPaths.isEmpty {
                throw ArchiveUtilityError.rejectedArchiveEntries(rejectedPaths)
            }
        } catch {
            if let error = error as? ArchiveUtilityError {
                throw error
            }
            throw ArchiveUtilityError.archiveReadFailed(error.localizedDescription)
        }
    }

    /// The compression wrapped around an uploaded archive, read from its magic
    /// bytes.
    ///
    /// `PUT /containers/{id}/archive` accepts a tar compressed with gzip, bzip2,
    /// xz or zstd as well as a plain one: moby runs every upload through
    /// `DecompressStream`. A reader pinned to `filter: .none` yields no entries
    /// for a compressed body and reports no error, so the copy would succeed
    /// while writing nothing. testcontainers-go always uploads gzip.
    static func compressionFilter(of tarPath: URL) -> Filter {
        guard let handle = try? FileHandle(forReadingFrom: tarPath) else { return .none }
        defer { try? handle.close() }
        let magic = [UInt8]((try? handle.read(upToCount: 10)) ?? Data())
        // A plain tar starts with its first member's name, so a short prefix is
        // not enough: `BZh-notes.txt` is a valid first member. Match as much of
        // each signature as the format fixes.
        if magic.starts(with: [0x1f, 0x8b, 0x08]) { return .gzip }
        // "BZh", a block size of '1'...'9', then either the block header
        // magic or, for a stream that opens with an empty member, the
        // end-of-stream magic.
        if magic.count >= 10, magic.starts(with: [0x42, 0x5a, 0x68]), (0x31...0x39).contains(magic[3]),
            magic[4...9].elementsEqual([0x31, 0x41, 0x59, 0x26, 0x53, 0x59])
                || magic[4...9].elementsEqual([0x17, 0x72, 0x45, 0x38, 0x50, 0x90])
        {
            return .bzip2
        }
        if magic.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return .xz }
        if magic.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) { return .zstd }
        // A zstd stream may open with a skippable frame (pzstd writes one):
        // magic 0x184D2A50...0x184D2A5F, little-endian.
        if magic.count >= 4, magic[0] & 0xf0 == 0x50, magic[1] == 0x2a, magic[2] == 0x4d, magic[3] == 0x18 { return .zstd }
        return .none
    }

    static func create(tarPath: URL, from source: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            throw ArchiveUtilityError.invalidPath
        }

        let writer: ArchiveWriter
        do {
            writer = try ArchiveWriter(
                format: .paxRestricted,
                filter: .none,
                file: tarPath
            )
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }

        do {
            try writer.archiveDirectory(source)
            try writer.finishEncoding()
        } catch {
            throw ArchiveUtilityError.archiveWriteFailed(error.localizedDescription)
        }
    }

    static func destinationPath(for entryPath: String?, under destinationPath: String) -> String? {
        guard var entryPath else {
            return nil
        }

        if entryPath.hasPrefix("./") {
            entryPath = String(entryPath.dropFirst(1))
        }
        if entryPath == "." || entryPath == "/" {
            return destinationPath
        }
        if !entryPath.hasPrefix("/") {
            entryPath = "/" + entryPath
        }

        if destinationPath == "/" {
            return entryPath
        }

        return destinationPath + entryPath
    }

    static func unpack(
        tarPath: URL,
        to formatter: EXT4.Formatter,
        destinationPath targetPath: String
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: compressionFilter(of: tarPath),
            file: tarPath
        )

        let bufferSize = 128 * 1024
        let reusableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
        defer { reusableBuffer.deallocate() }

        for (entry, streamReader) in archiveReader.makeStreamingIterator() {
            guard let fullPath = destinationPath(for: entry.path, under: targetPath) else {
                continue
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
                let symlinkTarget = entry.symlinkTarget.map { FilePath($0) }
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
        // A corrupt or truncated stream ends the iteration without throwing.
        try archiveReader.throwIfStreamFailed()
    }
}
