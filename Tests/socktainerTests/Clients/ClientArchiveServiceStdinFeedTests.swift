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
}
