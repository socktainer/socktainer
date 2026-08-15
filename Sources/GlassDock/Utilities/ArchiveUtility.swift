import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationOS
import Darwin
import Foundation
import SystemPackage

enum ArchiveUtilityError: Error, Equatable {
    case invalidPath
    case archiveCreationFailed(String)
    case archiveReadFailed(String)
    case archiveWriteFailed(String)
    case entryReadFailed(String)
    case rejectedArchiveEntries([String])
    case expandedBytesExceeded(maxBytes: Int64)
    case entryCountExceeded(maxEntries: Int)
    case decoderMemoryLimitExceeded(maxBytes: UInt64)
}

struct ArchiveUtility {

    struct ExtractionLimits: Equatable, Sendable {
        let maxExpandedBytes: Int64
        let maxEntries: Int
        let allowsSymbolicLinks: Bool

        init(
            maxExpandedBytes: Int64,
            maxEntries: Int,
            allowsSymbolicLinks: Bool = true
        ) {
            precondition(maxExpandedBytes >= 0)
            precondition(maxEntries >= 0)
            self.maxExpandedBytes = maxExpandedBytes
            self.maxEntries = maxEntries
            self.allowsSymbolicLinks = allowsSymbolicLinks
        }

        /// `/images/load` already bounds the compressed/request bytes to 64 GiB.
        /// Apply the same ceiling to materialized archive members and cap inode
        /// amplification independently. Real OCI and docker-archive layouts
        /// normally contain tens or hundreds of entries; 100,000 leaves ample
        /// headroom without making an empty-file bomb effectively unbounded.
        static let imageLoad = ExtractionLimits(
            maxExpandedBytes: 64 * 1024 * 1024 * 1024,
            maxEntries: 100_000,
            // OCI and legacy docker-save envelopes contain directories and
            // regular metadata/blob files only. Disallow links in the outer
            // archive so later manifest processing cannot be redirected even
            // if a future converter accidentally follows a member path.
            allowsSymbolicLinks: false
        )

        /// Classic Docker build contexts are commonly compressed. Permit a
        /// generous expansion over the 16-GiB request cap while keeping both
        /// disk use and inode creation deterministic.
        static let buildContext = ExtractionLimits(
            maxExpandedBytes: 64 * 1024 * 1024 * 1024,
            maxEntries: 250_000
        )

        fileprivate static let unbounded = ExtractionLimits(
            maxExpandedBytes: .max,
            maxEntries: .max
        )

        /// A zstd wrapper has to be decoded into a bounded plain-tar staging
        /// file because macOS libarchive cannot install its zstd read filter.
        /// Include tar headers/PAX metadata in that intermediate ceiling while
        /// retaining the stricter member-content quota during extraction.
        fileprivate var maxArchiveStreamBytes: Int64 {
            guard maxExpandedBytes != .max else { return .max }
            let entryOverhead: Int64
            let entryCount = Int64(maxEntries)
            let (calculatedOverhead, overflowed) =
                entryCount
                .multipliedReportingOverflow(by: 4096)
            entryOverhead = overflowed ? .max : calculatedOverhead
            let boundedOverhead = min(entryOverhead, maxExpandedBytes)
            let (withOverhead, firstOverflow) =
                maxExpandedBytes
                .addingReportingOverflow(boundedOverhead)
            guard !firstOverflow else { return .max }
            let (withTerminatorAllowance, secondOverflow) =
                withOverhead
                .addingReportingOverflow(1024 * 1024)
            return secondOverflow ? .max : withTerminatorAllowance
        }
    }

    /// Extracts a tar-family archive without unbounded decompression.
    /// `ArchiveReader(file:)` probes zstd by first expanding the entire input
    /// into an unrestricted temporary path. Compressed streams are instead
    /// decoded with fixed-size buffers into a private, quota-bound plain-tar
    /// staging file before the member-level extraction quota is enforced.
    ///
    /// When `transactional` is true, members are written into a private sibling
    /// directory and renamed into place only after a complete, uncancelled
    /// extraction. The caller must provide a destination that does not exist.
    static func extract(
        tarPath: URL,
        to destination: URL,
        limits: ExtractionLimits = .unbounded,
        transactional: Bool = false
    ) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: tarPath.path) else {
            throw ArchiveUtilityError.invalidPath
        }

        let extractionDestination: URL
        var removeExtractionDestination = false
        if transactional {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw ArchiveUtilityError.invalidPath
            }
            extractionDestination = destination.deletingLastPathComponent()
                .appendingPathComponent(
                    ".glassdock-extract-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: extractionDestination,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            removeExtractionDestination = true
        } else {
            extractionDestination = destination
            try fileManager.createDirectory(
                at: extractionDestination,
                withIntermediateDirectories: true
            )
        }
        defer {
            if removeExtractionDestination {
                try? fileManager.removeItem(at: extractionDestination)
            }
        }

        let archiveInput: StreamingTarInput
        do {
            archiveInput = try streamingTarInput(
                file: tarPath,
                limits: limits,
                temporaryParent:
                    extractionDestination
                    .deletingLastPathComponent()
            )
        } catch let error as ArchiveUtilityError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }
        defer { archiveInput.cleanUp() }

        do {
            let rejectedPaths = try extractContents(
                archiveInput.reader,
                to: extractionDestination,
                limits: limits
            )
            if !rejectedPaths.isEmpty {
                throw ArchiveUtilityError.rejectedArchiveEntries(rejectedPaths)
            }
            try Task.checkCancellation()

            if transactional {
                try fileManager.moveItem(
                    at: extractionDestination,
                    to: destination
                )
                removeExtractionDestination = false
            }
        } catch {
            if let error = error as? ArchiveUtilityError {
                throw error
            }
            if error is CancellationError {
                throw error
            }
            throw ArchiveUtilityError.archiveReadFailed(error.localizedDescription)
        }
    }

    private struct StreamingTarInput {
        let reader: ArchiveReader
        let temporaryDirectory: URL?

        func cleanUp() {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
    }

    private static func streamingTarInput(
        file: URL,
        limits: ExtractionLimits,
        temporaryParent: URL
    ) throws -> StreamingTarInput {
        let handle = try FileHandle(forReadingFrom: file)
        let filter: Filter
        do {
            filter = try archiveFilter(for: handle)
        } catch {
            try? handle.close()
            throw error
        }

        guard filter != .none else {
            do {
                return try StreamingTarInput(
                    reader: ArchiveReader(
                        format: .paxRestricted,
                        filter: .none,
                        fileHandle: handle
                    ),
                    temporaryDirectory: nil
                )
            } catch {
                try? handle.close()
                throw error
            }
        }

        // Materialize compressed input only through a fixed-buffer decoder and
        // a hard raw-stream ceiling. Counting the complete filtered byte stream
        // (rather than only parsed member payloads) also bounds adversarial PAX
        // records, tar padding, and other headers that ArchiveReader hides.
        // Containerization 0.40.1's URL initializer cannot provide this bound;
        // for zstd it also eagerly expands into its own unbounded temp file.
        try? handle.close()
        let temporaryDirectory =
            try RequestBodyFileWriter
            .createSecureTemporaryDirectory(in: temporaryParent)
        do {
            let plainTar = temporaryDirectory.appendingPathComponent(
                "archive.tar"
            )
            switch filter {
            case .gzip, .bzip2, .xz:
                let compression: FilteredStreamDecoder.Compression
                switch filter {
                case .gzip: compression = .gzip
                case .bzip2: compression = .bzip2
                case .xz: compression = .xz
                default: preconditionFailure("unreachable archive filter")
                }
                do {
                    try FilteredStreamDecoder.decompress(
                        source: file,
                        destination: plainTar,
                        compression: compression,
                        maxBytes: limits.maxArchiveStreamBytes,
                        maxDecoderMemoryBytes: FilteredStreamDecoder
                            .defaultMaximumDecoderMemoryBytes
                    )
                } catch FilteredStreamDecoder.Error.exceedsCap {
                    throw ArchiveUtilityError.expandedBytesExceeded(
                        maxBytes: limits.maxExpandedBytes
                    )
                } catch FilteredStreamDecoder.Error.memoryLimitExceeded {
                    throw ArchiveUtilityError.decoderMemoryLimitExceeded(
                        maxBytes: FilteredStreamDecoder
                            .defaultMaximumDecoderMemoryBytes
                    )
                }
            case .zstd:
                do {
                    try ZstdStreamDecoder.decompress(
                        source: file,
                        destination: plainTar,
                        maxBytes: limits.maxArchiveStreamBytes
                    )
                } catch ZstdStreamDecoder.Error.exceedsCap {
                    throw ArchiveUtilityError.expandedBytesExceeded(
                        maxBytes: limits.maxExpandedBytes
                    )
                }
            default:
                throw ArchiveUtilityError.archiveReadFailed(
                    "unsupported outer archive compression: \(filter.rawValue)"
                )
            }
            let plainHandle = try FileHandle(forReadingFrom: plainTar)
            do {
                return try StreamingTarInput(
                    reader: ArchiveReader(
                        format: .paxRestricted,
                        filter: .none,
                        fileHandle: plainHandle
                    ),
                    temporaryDirectory: temporaryDirectory
                )
            } catch {
                try? plainHandle.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private static func archiveFilter(for handle: FileHandle) throws -> Filter {
        let originalOffset = try handle.offset()
        defer { try? handle.seek(toOffset: originalOffset) }
        let prefix = try handle.read(upToCount: 8) ?? Data()

        if prefix.starts(with: [0x1f, 0x8b]) {
            return .gzip
        }
        if prefix.starts(with: [0x42, 0x5a, 0x68]) {
            return .bzip2
        }
        if prefix.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) {
            return .xz
        }
        if prefix.starts(with: [0x1f, 0x9d]) {
            return .compress
        }
        if prefix.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) {
            return .zstd
        }
        if prefix.count >= 4 {
            let magic =
                UInt32(prefix[prefix.startIndex])
                | UInt32(prefix[prefix.startIndex + 1]) << 8
                | UInt32(prefix[prefix.startIndex + 2]) << 16
                | UInt32(prefix[prefix.startIndex + 3]) << 24
            if magic & 0xffff_fff0 == 0x184d_2a50 {
                return .zstd
            }
        }
        return .none
    }

    private static func extractContents(
        _ reader: ArchiveReader,
        to destination: URL,
        limits: ExtractionLimits
    ) throws -> [String] {
        let rootPath = FilePath(destination.path)
        let rootFileDescriptor = try FileDescriptor.open(
            rootPath,
            .readOnly,
            options: [.directory, .noFollow, .closeOnExec]
        )
        defer { try? rootFileDescriptor.close() }

        var foundEntry = false
        var entryCount = 0
        var expandedBytes: Int64 = 0
        var rejectedPaths: [String] = []

        for (entry, dataReader) in reader.makeStreamingIterator() {
            try Task.checkCancellation()
            foundEntry = true

            guard entryCount < limits.maxEntries else {
                throw ArchiveUtilityError.entryCountExceeded(
                    maxEntries: limits.maxEntries
                )
            }
            entryCount += 1

            guard let rawPath = entry.path,
                let memberPath = safeRelativePath(rawPath)
            else {
                rejectedPaths.append(entry.path ?? "<missing path>")
                continue
            }

            if entry.fileType == .regular,
                let declaredSize = entry.size
            {
                guard declaredSize >= 0,
                    declaredSize <= limits.maxExpandedBytes - expandedBytes
                else {
                    throw ArchiveUtilityError.expandedBytesExceeded(
                        maxBytes: limits.maxExpandedBytes
                    )
                }
            }

            let extracted = try extractEntry(
                entry,
                dataReader: dataReader,
                memberPath: memberPath,
                rootFileDescriptor: rootFileDescriptor,
                expandedBytes: &expandedBytes,
                maxExpandedBytes: limits.maxExpandedBytes,
                allowsSymbolicLinks: limits.allowsSymbolicLinks
            )
            if !extracted {
                rejectedPaths.append(rawPath)
            }
        }

        guard foundEntry else {
            throw ArchiveUtilityError.archiveReadFailed(
                "no entries found in archive"
            )
        }
        return rejectedPaths
    }

    /// Converts a member path to an fd-anchored relative path. Leading `./`
    /// and redundant `.` components are normal tar spelling; absolute paths,
    /// `..`, and an empty non-root path are rejected before any filesystem
    /// operation occurs.
    private static func safeRelativePath(_ rawPath: String) -> FilePath? {
        guard !rawPath.hasPrefix("/"), !rawPath.utf8.contains(0) else {
            return nil
        }

        var components: [String] = []
        for component in rawPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            if component == "." {
                continue
            }
            guard component != ".." else { return nil }
            components.append(String(component))
        }

        if components.isEmpty {
            return rawPath == "." || rawPath == "./" ? FilePath("") : nil
        }
        return components.reduce(into: FilePath("")) {
            $0.append($1)
        }
    }

    private static func extractEntry(
        _ entry: WriteEntry,
        dataReader: ArchiveEntryReader,
        memberPath: FilePath,
        rootFileDescriptor: FileDescriptor,
        expandedBytes: inout Int64,
        maxExpandedBytes: Int64,
        allowsSymbolicLinks: Bool
    ) throws -> Bool {
        // A leading "./" directory describes the extraction root itself.
        guard let lastComponent = memberPath.lastComponent else {
            return entry.fileType == .directory
        }
        let parentPath = memberPath.removingLastComponent()

        do {
            switch entry.fileType {
            case .regular:
                // Apple Containerization's extractor does not materialize hard
                // links. Keep that behavior rather than following an archive-
                // controlled target path outside the descriptor-anchored walk.
                guard entry.hardlink == nil else { return false }

                try FileDescriptorOps.mkdir(
                    rootFileDescriptor,
                    parentPath,
                    makeIntermediates: true
                ) { parentFileDescriptor in
                    try? FileDescriptorOps.unlinkRecursive(
                        parentFileDescriptor,
                        filename: lastComponent
                    )

                    let rawFileDescriptor = openat(
                        parentFileDescriptor.rawValue,
                        lastComponent.string,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        entry.permissions & 0o777
                    )
                    guard rawFileDescriptor >= 0 else {
                        throw ArchiveUtilityError.entryReadFailed(
                            "failed to create file: \(memberPath.string)"
                        )
                    }
                    let fileDescriptor = FileDescriptor(
                        rawValue: rawFileDescriptor
                    )
                    defer { try? fileDescriptor.close() }

                    var buffer = [UInt8](
                        repeating: 0,
                        count: 1024 * 1024
                    )
                    var entryBytes: Int64 = 0
                    while true {
                        try Task.checkCancellation()
                        let bytesRead = buffer.withUnsafeMutableBufferPointer {
                            guard let baseAddress = $0.baseAddress else {
                                return 0
                            }
                            return dataReader.read(
                                baseAddress,
                                maxLength: $0.count
                            )
                        }
                        guard bytesRead >= 0 else {
                            throw ArchiveUtilityError.entryReadFailed(
                                memberPath.string
                            )
                        }
                        guard bytesRead > 0 else { break }

                        let count = Int64(bytesRead)
                        guard count <= maxExpandedBytes - expandedBytes else {
                            throw ArchiveUtilityError.expandedBytesExceeded(
                                maxBytes: maxExpandedBytes
                            )
                        }
                        expandedBytes += count
                        entryBytes += count
                        try fileDescriptor.writeAll(
                            buffer.prefix(bytesRead)
                        )
                    }

                    if let declaredSize = entry.size,
                        entryBytes != declaredSize
                    {
                        throw ArchiveUtilityError.entryReadFailed(
                            "size mismatch for \(memberPath.string)"
                        )
                    }
                    setFileAttributes(
                        fileDescriptor,
                        from: entry
                    )
                }

            case .directory:
                try FileDescriptorOps.mkdir(
                    rootFileDescriptor,
                    memberPath,
                    permissions: FilePermissions(
                        rawValue: entry.permissions & 0o777
                    ),
                    makeIntermediates: true
                ) { fileDescriptor in
                    setFileAttributes(fileDescriptor, from: entry)
                }

            case .symbolicLink:
                guard allowsSymbolicLinks else { return false }
                guard let target = entry.symlinkTarget else { return false }
                try FileDescriptorOps.mkdir(
                    rootFileDescriptor,
                    parentPath,
                    makeIntermediates: true
                ) { parentFileDescriptor in
                    try? FileDescriptorOps.unlinkRecursive(
                        parentFileDescriptor,
                        filename: lastComponent
                    )
                    guard
                        symlinkat(
                            target,
                            parentFileDescriptor.rawValue,
                            lastComponent.string
                        ) == 0
                    else {
                        throw ArchiveUtilityError.entryReadFailed(
                            "failed to create symlink: \(memberPath.string)"
                        )
                    }
                }

            default:
                return false
            }
            return true
        } catch let error as FileDescriptorOps.Error {
            switch error {
            case .invalidRelativePath, .invalidPathComponent,
                .cannotFollowSymlink:
                return false
            case .systemError:
                throw error
            }
        }
    }

    private static func setFileAttributes(
        _ fileDescriptor: FileDescriptor,
        from entry: WriteEntry
    ) {
        _ = fchmod(
            fileDescriptor.rawValue,
            entry.permissions & 0o777
        )
        if let owner = entry.owner, let group = entry.group {
            _ = fchown(fileDescriptor.rawValue, owner, group)
        }
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
            filter: .none,
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
    }
}
