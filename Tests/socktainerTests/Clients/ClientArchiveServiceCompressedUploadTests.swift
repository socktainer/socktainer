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
