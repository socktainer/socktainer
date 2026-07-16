import CryptoKit
import DataCompression
import Foundation
import Testing

@testable import socktainer

@Suite("GzipStreamDecoder")
struct GzipStreamDecoderTests {

    private func write(_ data: Data) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gz")
        try data.write(to: path)
        return path
    }

    /// Rebuilds a `DataCompression`-produced gzip's header with the FNAME
    /// flag set and a filename spliced in, leaving the DEFLATE payload and
    /// trailer untouched — exercises RFC 1952's optional-field handling
    /// without depending on the system `gzip` binary being present.
    private func withEmbeddedFilename(_ gzipped: Data, name: String) -> Data {
        var result = Data(gzipped.prefix(10))
        result[3] = 0x08  // FLG: FNAME
        result.append(contentsOf: name.utf8)
        result.append(0)
        result.append(gzipped.suffix(from: gzipped.startIndex + 10))
        return result
    }

    @Test("decompressed content hashes the same as DataCompression's gunzip")
    func matchesWholeBufferDecompression() throws {
        let content = Data("hello streaming gzip world, repeated. ".repeated(500).utf8)
        let path = try write(try #require(content.gzip()))
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 10_000_000)
        #expect(digest == content.sha256Hex())
    }

    @Test("a gzip header with an embedded filename (FNAME) is parsed correctly")
    func handlesEmbeddedFilename() throws {
        let content = Data("content behind an FNAME-bearing header".utf8)
        let plain = try #require(content.gzip())
        let path = try write(withEmbeddedFilename(plain, name: "original.tar"))
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 10_000_000)
        #expect(digest == content.sha256Hex())
    }

    @Test("a highly-compressible payload exceeding the cap is rejected mid-stream")
    func rejectsCompressionBomb() throws {
        let content = Data(repeating: 0, count: 1 << 20)  // 1 MiB of zeros compresses to ~1 KB
        let path = try write(try #require(content.gzip()))
        #expect(throws: GzipStreamDecoder.Error.exceedsCap) {
            _ = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 1000)
        }
    }

    @Test("a non-gzip file is rejected as an invalid header")
    func rejectsNonGzipInput() throws {
        let path = try write(Data(repeating: 0xFF, count: 64))
        #expect(throws: GzipStreamDecoder.Error.invalidHeader) {
            _ = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 10_000_000)
        }
    }
}

extension String {
    fileprivate func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
