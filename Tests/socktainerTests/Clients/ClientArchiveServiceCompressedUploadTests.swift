import ContainerizationArchive
import Foundation
import Testing

@testable import socktainer

/// `PUT /containers/{id}/archive` must accept a compressed tar: moby
/// decompresses every upload, and testcontainers-go always sends gzip. Before
/// the fix a compressed body parsed to an empty plan, so the copy returned 200
/// and wrote nothing.
@Suite("ClientArchiveService accepts compressed uploads")
struct ClientArchiveServiceCompressedUploadTests {

    @Test(
        "an uploaded tar yields the same copy plan whatever its compression",
        arguments: [
            (flag: "-cf", filter: Filter.none),
            (flag: "-czf", filter: Filter.gzip),
            (flag: "-cjf", filter: Filter.bzip2),
            (flag: "-cJf", filter: Filter.xz),
        ])
    func compressedUploadParsesToTheSamePlan(flag: String, filter: Filter) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("put-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("#!/bin/sh\necho started\n".utf8).write(to: dir.appendingPathComponent("starter.sh"))
        let archive = dir.appendingPathComponent("upload")
        try runTar([flag, archive.path, "-C", dir.path, "starter.sh"])

        #expect(ArchiveUtility.compressionFilter(of: archive) == filter)

        let service = ClientArchiveService(appSupportPath: dir, flushGuest: { _ in })
        let plan = try service.parseArchiveEntries(tarPath: archive, destinationPath: "/tmp")

        #expect(plan.count == 1)
        let entry = try #require(plan.first)
        #expect(entry.relativePath == "starter.sh")
        #expect(entry.guestPath == "/tmp/starter.sh")
        guard case .file = entry.kind else {
            Issue.record("expected a regular file entry, got \(entry.kind)")
            return
        }
    }

    @Test("an unreadable or empty upload is treated as uncompressed")
    func missingOrEmptyFileIsUncompressed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("put-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ArchiveUtility.compressionFilter(of: dir.appendingPathComponent("absent")) == .none)

        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(ArchiveUtility.compressionFilter(of: empty) == .none)
    }

    @Test("a plain tar whose first member name starts with a compression signature stays uncompressed")
    func plainTarWithSignatureLikeNameIsNotMisdetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("put-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // "BZh" opens every bzip2 stream, and a tar starts with its first
        // member's name.
        try Data("notes\n".utf8).write(to: dir.appendingPathComponent("BZh-notes.txt"))
        let archive = dir.appendingPathComponent("upload")
        try runTar(["-cf", archive.path, "-C", dir.path, "BZh-notes.txt"])

        #expect(ArchiveUtility.compressionFilter(of: archive) == .none)

        let service = ClientArchiveService(appSupportPath: dir, flushGuest: { _ in })
        let plan = try service.parseArchiveEntries(tarPath: archive, destinationPath: "/tmp")
        #expect(plan.map(\.guestPath) == ["/tmp/BZh-notes.txt"])
    }

    @Test("a zstd stream that opens with a skippable frame is detected")
    func zstdSkippableFrameIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("put-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Skippable frame magic 0x184D2A50, little-endian, as pzstd writes it.
        let file = dir.appendingPathComponent("upload")
        try Data([0x50, 0x2a, 0x4d, 0x18, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]).write(to: file)
        #expect(ArchiveUtility.compressionFilter(of: file) == .zstd)
    }

    @Test("a truncated compressed upload is refused, not half-applied")
    func truncatedCompressedUploadThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("put-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Incompressible content, so cutting the stream loses real data.
        var noise = Data(count: 256 * 1024)
        noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try noise.write(to: dir.appendingPathComponent("a.bin"))
        try noise.write(to: dir.appendingPathComponent("b.bin"))
        let whole = dir.appendingPathComponent("whole.tar.gz")
        try runTar(["-czf", whole.path, "-C", dir.path, "a.bin", "b.bin"])

        let bytes = try Data(contentsOf: whole)
        let truncated = dir.appendingPathComponent("truncated.tar.gz")
        try bytes.prefix(bytes.count / 2).write(to: truncated)

        let service = ClientArchiveService(appSupportPath: dir, flushGuest: { _ in })
        #expect(try service.parseArchiveEntries(tarPath: whole, destinationPath: "/tmp").count == 2)
        do {
            _ = try service.parseArchiveEntries(tarPath: truncated, destinationPath: "/tmp")
            Issue.record("expected invalidArchive")
        } catch let error as ClientArchiveError {
            // invalidArchive is what the route maps to 400.
            guard case .invalidArchive = error else {
                Issue.record("expected invalidArchive, got \(error)")
                return
            }
        }
    }

    @Test("a bzip2 stream that opens with an empty member is detected and decoded")
    func bzip2EmptyFirstMemberIsDecoded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("put-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("notes\n".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let member = dir.appendingPathComponent("member.tar.bz2")
        try runTar(["-cjf", member.path, "-C", dir.path, "notes.txt"])

        // bzip2 of empty input: "BZh9", the end-of-stream magic, a zero CRC.
        // Concatenated members decompress to their combined contents.
        let emptyMember = Data([0x42, 0x5a, 0x68, 0x39, 0x17, 0x72, 0x45, 0x38, 0x50, 0x90, 0x00, 0x00, 0x00, 0x00])
        let archive = dir.appendingPathComponent("upload")
        try (emptyMember + Data(contentsOf: member)).write(to: archive)

        #expect(ArchiveUtility.compressionFilter(of: archive) == .bzip2)

        let service = ClientArchiveService(appSupportPath: dir, flushGuest: { _ in })
        let plan = try service.parseArchiveEntries(tarPath: archive, destinationPath: "/tmp")
        #expect(plan.map(\.guestPath) == ["/tmp/notes.txt"])
    }

    private func runTar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        // Keep macOS metadata (._ files) out of the archive.
        process.environment = ["COPYFILE_DISABLE": "1"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
