import ContainerizationArchive
import Foundation
import Testing

@testable import GlassDock

@Suite("Bounded archive extraction")
struct ArchiveUtilityTests {
    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        func archive(
            named name: String = "fixture.tar",
            filter: Filter = .none,
            files: [(String, Data)]
        ) throws -> URL {
            let path = root.appendingPathComponent(name)
            let writer = try ArchiveWriter(
                format: .paxRestricted,
                filter: filter,
                file: path
            )
            for (memberPath, data) in files {
                let entry = WriteEntry()
                entry.path = memberPath
                entry.size = Int64(data.count)
                entry.fileType = .regular
                entry.permissions = 0o644
                try writer.writeEntry(entry: entry, data: data)
            }
            try writer.finishEncoding()
            return path
        }

        func symlinkTraversalArchive() throws -> URL {
            let path = root.appendingPathComponent("symlink-traversal.tar")
            let writer = try ArchiveWriter(
                format: .paxRestricted,
                filter: .none,
                file: path
            )
            let link = WriteEntry()
            link.path = "pivot"
            link.size = 0
            link.fileType = .symbolicLink
            link.symlinkTarget = ".."
            link.permissions = 0o777
            try writer.writeEntry(entry: link, data: nil)

            let file = WriteEntry()
            file.path = "pivot/escaped"
            file.size = 4
            file.fileType = .regular
            file.permissions = 0o644
            try writer.writeEntry(entry: file, data: Data("safe".utf8))
            try writer.finishEncoding()
            return path
        }

        func hardlinkArchive() throws -> URL {
            let path = root.appendingPathComponent("hardlink.tar")
            let writer = try ArchiveWriter(
                format: .paxRestricted,
                filter: .none,
                file: path
            )
            let original = WriteEntry()
            original.path = "original"
            original.size = 4
            original.fileType = .regular
            original.permissions = 0o644
            try writer.writeEntry(
                entry: original,
                data: Data("data".utf8)
            )

            let link = WriteEntry()
            link.path = "alias"
            link.hardlink = "original"
            link.size = 0
            link.fileType = .regular
            link.permissions = 0o644
            try writer.writeEntry(entry: link, data: nil)
            try writer.finishEncoding()
            return path
        }

        /// Writes one valid ustar header whose declared payload is deliberately
        /// absent. The extractor must reject from header metadata before trying
        /// to create or drain the enormous member.
        func archiveDeclaringHugeEntry(size: Int64) throws -> URL {
            var header = [UInt8](repeating: 0, count: 512)
            write("huge.bin", into: &header, at: 0, width: 100)
            writeOctal(0o644, into: &header, at: 100, width: 8)
            writeOctal(0, into: &header, at: 108, width: 8)
            writeOctal(0, into: &header, at: 116, width: 8)
            writeOctal(size, into: &header, at: 124, width: 12)
            writeOctal(0, into: &header, at: 136, width: 12)
            for offset in 148..<156 { header[offset] = 0x20 }
            header[156] = 0x30
            write("ustar", into: &header, at: 257, width: 6)
            write("00", into: &header, at: 263, width: 2)

            let checksum = header.reduce(0) { $0 + Int($1) }
            let octal = String(checksum, radix: 8)
            let checksumField =
                String(
                    repeating: "0",
                    count: max(0, 6 - octal.count)
                ) + octal + "\0 "
            write(checksumField, into: &header, at: 148, width: 8)

            let path = root.appendingPathComponent("declared-huge.tar")
            var archive = Data(header)
            archive.append(Data(count: 1024))
            try archive.write(to: path)
            return path
        }

        func archiveRequiringHugeXZDictionary() throws -> URL {
            let path = try archive(
                named: "huge-dictionary.tar.xz",
                filter: .xz,
                files: [("hello.txt", Data("hello".utf8))]
            )
            var bytes = try Data(contentsOf: path)
            let blockHeaderStart = 12
            guard bytes.count > blockHeaderStart,
                bytes.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])
            else {
                throw ArchiveUtilityError.archiveCreationFailed(
                    "test fixture is not an xz stream"
                )
            }
            let blockHeaderSize = (Int(bytes[blockHeaderStart]) + 1) * 4
            let blockHeaderEnd = blockHeaderStart + blockHeaderSize
            guard blockHeaderEnd <= bytes.count,
                let filterIDOffset = (blockHeaderStart + 2..<blockHeaderEnd - 6)
                    .first(where: {
                        bytes[$0] == 0x21 && bytes[$0 + 1] == 0x01
                    })
            else {
                throw ArchiveUtilityError.archiveCreationFailed(
                    "test fixture has no LZMA2 filter properties"
                )
            }

            // XZ's LZMA2 property 40 advertises UINT32_MAX dictionary bytes.
            // The payload itself remains tiny; only the hostile decoder-memory
            // requirement changes. Recompute the little-endian block-header
            // CRC so rejection proves the configured memory limit, not corrupt
            // input handling.
            bytes[filterIDOffset + 2] = 40
            let crcOffset = blockHeaderEnd - 4
            let crc = crc32(bytes[blockHeaderStart..<crcOffset])
            for offset in 0..<4 {
                bytes[crcOffset + offset] = UInt8(
                    truncatingIfNeeded: crc >> UInt32(offset * 8)
                )
            }
            try bytes.write(to: path)
            return path
        }

        private func crc32(_ bytes: Data.SubSequence) -> UInt32 {
            var checksum = UInt32.max
            for byte in bytes {
                checksum ^= UInt32(byte)
                for _ in 0..<8 {
                    let mask = UInt32(bitPattern: -Int32(checksum & 1))
                    checksum = (checksum >> 1) ^ (0xedb8_8320 & mask)
                }
            }
            return ~checksum
        }

        private func write(
            _ value: String,
            into bytes: inout [UInt8],
            at offset: Int,
            width: Int
        ) {
            for (index, byte) in value.utf8.prefix(width).enumerated() {
                bytes[offset + index] = byte
            }
        }

        private func writeOctal(
            _ value: Int64,
            into bytes: inout [UInt8],
            at offset: Int,
            width: Int
        ) {
            let octal = String(value, radix: 8)
            let field =
                String(
                    repeating: "0",
                    count: max(0, width - octal.count - 1)
                ) + octal + "\0"
            write(field, into: &bytes, at: offset, width: width)
        }
    }

    @Test("gzip bombs are rejected from the declared expanded size")
    func compressionBombIsBounded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.archive(
            named: "bomb.tar.gz",
            filter: .gzip,
            files: [("zeros", Data(count: 2 * 1024 * 1024))]
        )
        let compressedSize = try #require(
            (try FileManager.default.attributesOfItem(atPath: archive.path)[.size])
                as? NSNumber
        ).intValue
        #expect(compressedSize < 64 * 1024)

        let destination = fixture.root.appendingPathComponent("output")
        #expect(
            throws: ArchiveUtilityError.expandedBytesExceeded(
                maxBytes: 64 * 1024
            )
        ) {
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(
                    maxExpandedBytes: 64 * 1024,
                    maxEntries: 10
                ),
                transactional: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try partialExtractionNames(in: fixture.root).isEmpty)
    }

    @Test("an oversized declared member is rejected before extraction")
    func declaredHugeEntryIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.archiveDeclaringHugeEntry(
            size: 8 * 1024 * 1024 * 1024
        )
        let destination = fixture.root.appendingPathComponent("output")

        #expect(
            throws: ArchiveUtilityError.expandedBytesExceeded(
                maxBytes: 1024 * 1024
            )
        ) {
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(
                    maxExpandedBytes: 1024 * 1024,
                    maxEntries: 10
                ),
                transactional: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("entry-count quota prevents empty-file inode amplification")
    func tooManyEntriesAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.archive(
            files: (0..<5).map { ("empty-\($0)", Data()) }
        )
        let destination = fixture.root.appendingPathComponent("output")

        #expect(
            throws: ArchiveUtilityError.entryCountExceeded(maxEntries: 3)
        ) {
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(maxExpandedBytes: 1024, maxEntries: 3),
                transactional: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try partialExtractionNames(in: fixture.root).isEmpty)
    }

    @Test("dot-dot paths are rejected and transactional output is removed")
    func traversalIsRejectedAndCleanedUp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.archive(
            files: [("../escaped", Data("evil".utf8))]
        )
        let destination = fixture.root.appendingPathComponent("output")
        let escaped = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("escaped")
        try? FileManager.default.removeItem(at: escaped)

        #expect(
            throws: ArchiveUtilityError.rejectedArchiveEntries([
                "../escaped"
            ])
        ) {
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(maxExpandedBytes: 1024, maxEntries: 10),
                transactional: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try partialExtractionNames(in: fixture.root).isEmpty)
    }

    @Test("an archive symlink cannot redirect a later member outside the root")
    func symlinkTraversalCannotEscape() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.symlinkTraversalArchive()
        let destination = fixture.root.appendingPathComponent("output")
        let escaped = fixture.root.appendingPathComponent("escaped")

        try ArchiveUtility.extract(
            tarPath: archive,
            to: destination,
            limits: .init(maxExpandedBytes: 1024, maxEntries: 10),
            transactional: true
        )

        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(
            try String(
                contentsOf: destination.appendingPathComponent(
                    "pivot/escaped"
                ),
                encoding: .utf8
            ) == "safe"
        )
    }

    @Test("image envelopes reject symbolic-link members")
    func imageEnvelopeRejectsSymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.symlinkTraversalArchive()
        let destination = fixture.root.appendingPathComponent("output")

        #expect(
            throws: ArchiveUtilityError.rejectedArchiveEntries(["pivot"])
        ) {
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(
                    maxExpandedBytes: 1024,
                    maxEntries: 10,
                    allowsSymbolicLinks: false
                ),
                transactional: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("hard-link members are rejected instead of following archive paths")
    func hardlinksAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.hardlinkArchive()
        let destination = fixture.root.appendingPathComponent("output")

        #expect(
            throws: ArchiveUtilityError.rejectedArchiveEntries(["alias"])
        ) {
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(maxExpandedBytes: 1024, maxEntries: 10),
                transactional: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("zstd tar input streams and extracts normally")
    func zstdArchiveLoadsNormally() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let plainArchive = try fixture.archive(
            named: "normal.tar",
            files: [("hello.txt", Data("hello".utf8))]
        )
        let archive = fixture.root.appendingPathComponent("normal.tar.zst")
        try ZstdTestSupport.compress(
            source: plainArchive,
            destination: archive
        )
        let destination = fixture.root.appendingPathComponent("output")

        try ArchiveUtility.extract(
            tarPath: archive,
            to: destination,
            limits: .init(maxExpandedBytes: 1024, maxEntries: 10),
            transactional: true
        )

        #expect(
            try String(
                contentsOf: destination.appendingPathComponent("hello.txt"),
                encoding: .utf8
            ) == "hello"
        )
    }

    @Test("zstd staging never follows or truncates an existing output link")
    func zstdOutputSymlinkIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let plainArchive = try fixture.archive(
            named: "normal.tar",
            files: [("hello.txt", Data("hello".utf8))]
        )
        let archive = fixture.root.appendingPathComponent("normal.tar.zst")
        try ZstdTestSupport.compress(
            source: plainArchive,
            destination: archive
        )
        let canary = fixture.root.appendingPathComponent("canary")
        let canaryData = Data("must remain untouched".utf8)
        try canaryData.write(to: canary)
        let destination = fixture.root.appendingPathComponent("output.tar")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: canary
        )

        #expect(throws: ZstdStreamDecoder.Error.initializationFailed) {
            try ZstdStreamDecoder.decompress(
                source: archive,
                destination: destination,
                maxBytes: 1024 * 1024
            )
        }
        #expect(try Data(contentsOf: canary) == canaryData)
    }

    @Test("xz streams requiring huge dictionaries are rejected before allocation")
    func xzDecoderMemoryIsBounded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.archiveRequiringHugeXZDictionary()
        let destination = fixture.root.appendingPathComponent("output")

        #expect(
            throws: ArchiveUtilityError.decoderMemoryLimitExceeded(
                maxBytes: FilteredStreamDecoder
                    .defaultMaximumDecoderMemoryBytes
            )
        ) {
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(
                    maxExpandedBytes: 1024 * 1024,
                    maxEntries: 10
                ),
                transactional: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try partialExtractionNames(in: fixture.root).isEmpty)
    }

    @Test("cancellation removes the private partial extraction")
    func cancellationCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try fixture.archive(
            files: [("hello.txt", Data("hello".utf8))]
        )
        let destination = fixture.root.appendingPathComponent("output")
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            try ArchiveUtility.extract(
                tarPath: archive,
                to: destination,
                limits: .init(maxExpandedBytes: 1024, maxEntries: 10),
                transactional: true
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try partialExtractionNames(in: fixture.root).isEmpty)
    }

    private func partialExtractionNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".glassdock-extract-") }
    }
}
