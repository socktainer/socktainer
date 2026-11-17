import Foundation
import Testing

@testable import socktainer

@Suite("ClientArchiveService feeding a staged file to a guest's stdin")
struct ClientArchiveServiceStdinFeedTests {

    private func stagedFile(bytes count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stdin-feed-\(UUID().uuidString)")
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        return url
    }

    @Test("a write that fails is reported to the caller, not dropped")
    func writeFailureIsReported() async throws {
        let source = try stagedFile(bytes: 4 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: source) }
        let pipe = Pipe()
        // The guest process is gone: nobody reads the other end.
        try pipe.fileHandleForReading.close()

        await #expect(throws: (any Error).self, "a truncated file would otherwise be reported as copied") {
            try await ClientArchiveService.streamFileToStdin(writer: pipe.fileHandleForWriting, source: source)
        }
    }

    @Test("the file arrives byte for byte and stdin is closed afterwards")
    func bytesArriveIntact() async throws {
        let source = try stagedFile(bytes: 3 * 1024 * 1024 + 17)
        defer { try? FileManager.default.removeItem(at: source) }
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let received = Task.detached { () -> Data in reader.readDataToEndOfFile() }

        try await ClientArchiveService.streamFileToStdin(writer: pipe.fileHandleForWriting, source: source)

        #expect(await received.value == (try Data(contentsOf: source)), "EOF must follow the last byte")
    }

    @Test("a guest's stderr is drained to EOF and kept only up to the cap")
    func stderrIsDrainedAndCapped() async throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let chatter = Data(repeating: 0x61, count: 256 * 1024)
        let collected = ClientArchiveService.drainCapped(pipe.fileHandleForReading, limit: 16 * 1024)

        // A reader that stopped at the cap would close its end and fail this write.
        try writer.write(contentsOf: chatter)
        try writer.close()

        let kept = await collected.value.count
        #expect(kept >= 16 * 1024, "the first bytes up to the cap are kept")
        #expect(kept < 16 * 1024 + 4096, "nothing past the cap's last read is kept, got \(kept)")
    }
}
