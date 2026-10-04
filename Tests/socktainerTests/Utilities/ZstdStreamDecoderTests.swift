import Foundation
import Testing
import libzstd

@testable import socktainer

@Suite("ZstdStreamDecoder")
struct ZstdStreamDecoderTests {

    private func compress(_ data: Data) throws -> Data {
        var output = Data(count: ZSTD_compressBound(data.count))
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                ZSTD_compress(out.baseAddress, out.count, input.baseAddress, input.count, 3)
            }
        }
        try #require(ZSTD_isError(written) == 0)
        return output.prefix(written)
    }

    private func write(_ data: Data) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zst")
        try data.write(to: path)
        return path
    }

    /// Larger than one `ZSTD_DStreamOutSize()` buffer and highly compressible,
    /// so a single input chunk yields several full output buffers to drain.
    @Test("decompressed content hashes the same as the original")
    func matchesOriginalContent() throws {
        let content = Data(repeating: 0x61, count: 4 << 20)
        let path = try write(try compress(content))
        #expect(try ZstdStreamDecoder.sha256OfDecompressedContent(at: path, cap: 10 << 20) == content.sha256Hex())
    }

    @Test("concatenated frames hash as one continuous stream")
    func decodesConcatenatedFrames() throws {
        let first = Data("first frame\n".utf8)
        let second = Data("second frame\n".utf8)
        let path = try write(try compress(first) + compress(second))
        #expect(try ZstdStreamDecoder.sha256OfDecompressedContent(at: path, cap: 1000) == (first + second).sha256Hex())
    }

    @Test("a highly-compressible payload exceeding the cap is rejected mid-stream")
    func rejectsCompressionBomb() throws {
        let path = try write(try compress(Data(repeating: 0, count: 1 << 20)))
        #expect(throws: ZstdStreamDecoder.Error.exceedsCap) {
            _ = try ZstdStreamDecoder.sha256OfDecompressedContent(at: path, cap: 1000)
        }
    }

    @Test("a truncated frame is rejected")
    func rejectsTruncatedFrame() throws {
        let content = Data((0..<100_000).map { UInt8($0 % 251) })
        let compressed = try compress(content)
        let path = try write(compressed.prefix(compressed.count / 2))
        #expect(throws: (any Error).self) {
            _ = try ZstdStreamDecoder.sha256OfDecompressedContent(at: path, cap: 1 << 20)
        }
    }

    @Test("empty or non-zstd input is rejected")
    func rejectsInvalidInput() throws {
        for data in [Data(), Data(repeating: 0xFF, count: 64)] {
            let path = try write(data)
            #expect(throws: (any Error).self) {
                _ = try ZstdStreamDecoder.sha256OfDecompressedContent(at: path, cap: 1000)
            }
        }
    }
}
