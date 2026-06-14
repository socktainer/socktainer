import Foundation
import Testing

@testable import socktainer

/// `docker compose build` with the classic builder streams a build-context tar
/// whose final entry is not padded to a 512-byte block and which omits the
/// end-of-archive marker. The Docker daemon's Go tar reader tolerates this, but
/// libarchive (used by `ArchiveUtility.extract`) treats the short final block as
/// a truncated archive and aborts. `BuildRoute.appendTarTerminator` repairs such
/// a context by appending a zero-filled terminator before extraction.
@Suite("Build context tar terminator")
struct BuildContextTarTests {

    /// Build a tar of a single file, then strip the trailing zero bytes so the
    /// last entry's block is unpadded and the end-of-archive marker is gone —
    /// reproducing the classic-builder context tar that libarchive rejects.
    private func makeUnpaddedTar() throws -> (tar: URL, cleanup: () -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: source.appendingPathComponent("file.txt"))

        let fullTar = tmp.appendingPathComponent("full.tar")
        try ArchiveUtility.create(tarPath: fullTar, from: source)

        var bytes = try Data(contentsOf: fullTar)
        while bytes.last == 0 {
            bytes.removeLast()
        }
        let unpadded = tmp.appendingPathComponent("context.tar")
        try bytes.write(to: unpadded)
        return (unpadded, cleanup)
    }

    @Test("A plain tar missing its trailing padding fails to extract until terminated")
    func plainTarTerminator() throws {
        let (tar, cleanup) = try makeUnpaddedTar()
        defer { cleanup() }

        let destBefore = tar.deletingLastPathComponent().appendingPathComponent("before")
        #expect(throws: (any Error).self) {
            try ArchiveUtility.extract(tarPath: tar, to: destBefore)
        }

        try BuildRoute.appendTarTerminator(to: tar)

        let destAfter = tar.deletingLastPathComponent().appendingPathComponent("after")
        try ArchiveUtility.extract(tarPath: tar, to: destAfter)
        let extracted = try String(contentsOf: destAfter.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(extracted == "hello")
    }

    @Test("A gzip-compressed tar missing its trailing padding fails to extract until terminated")
    func gzipTarTerminator() throws {
        let (plainTar, cleanup) = try makeUnpaddedTar()
        defer { cleanup() }

        // Compress the unpadded tar so the missing end-of-archive marker is
        // inside the gzip stream, matching what `docker compose build` sends
        // (Content-Type: application/x-tar, gzip payload).
        let gzTar = plainTar.deletingLastPathComponent().appendingPathComponent("context.tar.gz")
        FileManager.default.createFile(atPath: gzTar.path, contents: nil)
        let out = try FileHandle(forWritingTo: gzTar)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gzip.arguments = ["gzip", "-c", plainTar.path]
        gzip.standardOutput = out
        try gzip.run()
        gzip.waitUntilExit()
        try out.close()
        #expect(gzip.terminationStatus == 0)

        let destBefore = gzTar.deletingLastPathComponent().appendingPathComponent("gzbefore")
        #expect(throws: (any Error).self) {
            try ArchiveUtility.extract(tarPath: gzTar, to: destBefore)
        }

        try BuildRoute.appendTarTerminator(to: gzTar)

        let destAfter = gzTar.deletingLastPathComponent().appendingPathComponent("gzafter")
        try ArchiveUtility.extract(tarPath: gzTar, to: destAfter)
        let extracted = try String(contentsOf: destAfter.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(extracted == "hello")
    }

    @Test("Terminating an already well-formed tar leaves it extractable")
    func wellFormedTarStaysValid() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "world".data(using: .utf8)!.write(to: source.appendingPathComponent("file.txt"))

        let tar = tmp.appendingPathComponent("context.tar")
        try ArchiveUtility.create(tarPath: tar, from: source)

        // Appending to a complete archive is a no-op for readers: trailing zeros
        // after the end-of-archive marker are ignored.
        try BuildRoute.appendTarTerminator(to: tar)

        let dest = tmp.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tar, to: dest)
        let extracted = try String(contentsOf: dest.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(extracted == "world")
    }
}
