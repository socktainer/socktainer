import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import GlassDock

@Suite("Bounded archive metadata reads")
struct BoundedFileReaderTests {
    @Test("the exact metadata bound succeeds and the next byte is rejected")
    func byteBoundIsEnforced() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1234".utf8).write(
            to: root.appendingPathComponent("metadata.json")
        )

        #expect(
            try BoundedFileReader.read(
                relativePath: "metadata.json",
                under: root,
                maxBytes: 4
            ) == Data("1234".utf8)
        )
        #expect(
            throws: BoundedFileReadError.exceedsLimit(
                path: "metadata.json",
                maxBytes: 3
            )
        ) {
            try BoundedFileReader.read(
                relativePath: "metadata.json",
                under: root,
                maxBytes: 3
            )
        }
    }

    @Test("metadata reads do not follow final or intermediate symbolic links")
    func linksAreRejected() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.json"),
            withDestinationURL: outside
        )
        let realDirectory = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        try Data("{}".utf8).write(
            to: realDirectory.appendingPathComponent("index.json")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("pivot"),
            withDestinationURL: realDirectory
        )

        #expect(throws: BoundedFileReadError.self) {
            try BoundedFileReader.readImageMetadata(
                relativePath: "linked.json",
                under: root
            )
        }
        #expect(throws: BoundedFileReadError.self) {
            try BoundedFileReader.readImageMetadata(
                relativePath: "pivot/index.json",
                under: root
            )
        }
    }

    @Test("an oversized top-level OCI index is rejected before JSON decoding")
    func oversizedOCIIndexIsRejected() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSparseFile(
            at: root.appendingPathComponent("index.json"),
            size: BoundedFileReader.maxImageMetadataBytes + 1
        )

        #expect(
            throws: BoundedFileReadError.exceedsLimit(
                path: "index.json",
                maxBytes: BoundedFileReader.maxImageMetadataBytes
            )
        ) {
            try OCILayoutPruner.pruneManifestsWithMissingBlobs(
                at: root,
                logger: Logger(label: "test")
            )
        }
    }

    @Test("an oversized OCI manifest blob is rejected before JSON decoding")
    func oversizedOCIManifestIsRejected() throws {
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hex = String(repeating: "a", count: 64)
        let relativePath = "blobs/sha256/\(hex)"
        let blob = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: blob.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeSparseFile(
            at: blob,
            size: BoundedFileReader.maxImageMetadataBytes + 1
        )
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: "sha256:\(hex)",
            size: Int64(BoundedFileReader.maxImageMetadataBytes + 1)
        )

        #expect(
            throws: BoundedFileReadError.exceedsLimit(
                path: relativePath,
                maxBytes: BoundedFileReader.maxImageMetadataBytes
            )
        ) {
            try OCILayoutPruner.artifactMetadata(
                for: descriptor,
                in: root
            )
        }
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func makeSparseFile(at url: URL, size: Int) throws {
        guard
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw BoundedFileReadError.cannotOpen(url.lastPathComponent)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
}
