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

    @Test("a gzip member with no content decodes to an empty digest")
    func emptyMemberDecodesToEmptyContent() throws {
        let content = Data()
        let path = try write(try #require(content.gzip()))
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 1_000_000)
        #expect(digest == content.sha256Hex())
    }

    @Test("a DEFLATE stream truncated mid-member is rejected, not silently accepted")
    func truncatedMemberFailsCleanly() throws {
        let content = Data(String(repeating: "some real content that needs a truncated stream check. ", count: 200).utf8)
        let compressed = try #require(content.gzip())
        let path = try write(compressed.prefix(compressed.count / 2))
        #expect(throws: (any Error).self) {
            _ = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 1_000_000)
        }
    }

    /// `cat a.gz b.gz > combined.gz` is a valid gzip file per RFC 1952 §2.2 —
    /// real `gunzip` and Go's `compress/gzip` (moby's own decoder, which
    /// defaults `Multistream: true`) both decompress it as the concatenation
    /// of every member's content, not just the first.
    @Test("concatenated gzip members hash as one continuous decompressed stream")
    func decodesConcatenatedMembers() throws {
        let first = Data("first member content\n".utf8)
        let second = Data("second member content\n".utf8)
        let third = Data("third member content\n".utf8)
        var combined = try #require(first.gzip())
        combined.append(try #require(second.gzip()))
        combined.append(try #require(third.gzip()))

        let path = try write(combined)
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 10_000_000)
        #expect(digest == (first + second + third).sha256Hex())
    }

    /// The multi-member boundary search only re-decodes when there's a
    /// concrete reason to suspect ambiguity; a lone large member spanning
    /// several chunks must never pay that cost.
    @Test("a large single-member gzip decodes without disambiguation overhead")
    func largeSingleMemberStaysFast() throws {
        let content = Data((0..<5_000_000).map { UInt8($0 % 251) })
        let path = try write(try #require(content.gzip()))
        let start = Date()
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 100_000_000)
        #expect(-start.timeIntervalSinceNow < 2.0, "a lone large member should skip the boundary search entirely")
        #expect(digest == content.sha256Hex())
    }

    @Test("a large member followed by a small member still decodes correctly")
    func largeMemberFollowedBySmallMember() throws {
        let large = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let small = Data("tiny trailing member\n".utf8)
        var combined = try #require(large.gzip())
        combined.append(try #require(small.gzip()))
        let path = try write(combined)
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 100_000_000)
        #expect(digest == (large + small).sha256Hex())
    }

    /// Regression for a real failure: a small, HIGHLY compressible first
    /// member (its whole compressed form well under one read's worth) landed
    /// in the same chunk read as a large chunk of a second member's own
    /// compressed bytes. `compression_stream_process` swallowed a big enough
    /// slice of that second member's DEFLATE stream to reach a false-positive
    /// `END` deep inside it, converging the (then-buggy) boundary search on
    /// entirely the wrong length. Low-entropy synthetic data (like
    /// `largeMemberFollowedBySmallMember`'s mod-251 pattern) doesn't
    /// reproduce this — it needs content that compresses well, same as a
    /// real tar of a real filesystem.
    @Test("a small, highly-compressible member followed by a large member decodes correctly")
    func smallCompressibleMemberFollowedByLargeMember() throws {
        let first = Data("repetitive, highly compressible content. ".repeated(3000).utf8)
        let second = Data((0..<2_000_000).map { UInt8(($0 / 37) % 256) })
        var combined = try #require(first.gzip())
        combined.append(try #require(second.gzip()))
        let path = try write(combined)
        let digest = try GzipStreamDecoder.sha256OfDecompressedContent(at: path, cap: 100_000_000)
        #expect(digest == (first + second).sha256Hex())
    }
}

extension String {
    fileprivate func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
