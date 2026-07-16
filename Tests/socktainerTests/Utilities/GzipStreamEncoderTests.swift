import CryptoKit
import Foundation
import Testing

@testable import socktainer

@Suite("GzipStreamEncoder")
struct GzipStreamEncoderTests {
    private func write(_ data: Data) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: path)
        return path
    }

    /// The real correctness bar: not "does my own decoder accept its own
    /// encoder's output" (circular), but does the system `gzip` binary — a
    /// completely independent implementation — accept it and recover the
    /// exact original bytes.
    private func realGunzipDecodes(_ path: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", path.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return output
    }

    @Test("real gunzip decodes the output back to the exact original content")
    func realGunzipRoundTrip() throws {
        let content = Data(String(repeating: "streamed gzip encoder content, repeated many times. ", count: 400).utf8)
        let sourcePath = try write(content)
        let destinationPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let result = try GzipStreamEncoder.compressFile(at: sourcePath, to: destinationPath)

        #expect(try realGunzipDecodes(destinationPath) == content)
        #expect(result.uncompressedDigest == content.sha256Hex())
    }

    @Test("the reported compressed digest and size match the actual written file")
    func compressedDigestIsSelfConsistent() throws {
        let content = Data("some layer content".utf8)
        let sourcePath = try write(content)
        let destinationPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let result = try GzipStreamEncoder.compressFile(at: sourcePath, to: destinationPath)

        let written = try Data(contentsOf: destinationPath)
        #expect(result.compressedDigest == written.sha256Hex())
        #expect(result.compressedSize == written.count)
    }

    @Test("an empty source file encodes to a valid, empty gzip stream")
    func emptySourceEncodesCorrectly() throws {
        let sourcePath = try write(Data())
        let destinationPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let result = try GzipStreamEncoder.compressFile(at: sourcePath, to: destinationPath)

        #expect(try realGunzipDecodes(destinationPath).isEmpty)
        #expect(result.uncompressedDigest == Data().sha256Hex())
    }

    @Test("a multi-chunk source streams and decodes correctly, matching moby's own streaming encoder")
    func largeSourceStreamsCorrectly() throws {
        let content = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let sourcePath = try write(content)
        let destinationPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let result = try GzipStreamEncoder.compressFile(at: sourcePath, to: destinationPath)

        #expect(try realGunzipDecodes(destinationPath) == content)
        #expect(result.uncompressedDigest == content.sha256Hex())
    }

    @Test("the encoded output round-trips through this codebase's own streaming decoder")
    func roundTripsThroughOwnDecoder() throws {
        let content = Data("round trip through GzipStreamDecoder".utf8)
        let sourcePath = try write(content)
        let destinationPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        _ = try GzipStreamEncoder.compressFile(at: sourcePath, to: destinationPath)
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: destinationPath, cap: 10_000_000)
        #expect(digest == content.sha256Hex())
    }
}
