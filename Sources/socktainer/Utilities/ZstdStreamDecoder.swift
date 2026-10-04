import CryptoKit
import Foundation
import libzstd

/// Streams a zstd file's decompressed content through libzstd in fixed-size
/// chunks, hashing as it goes, so a small highly-compressible input can't
/// expand on disk or in memory before the size `cap` is enforced.
/// Concatenated frames decode as one continuous stream, like `zstd -d`.
enum ZstdStreamDecoder {
    enum Error: Swift.Error, Equatable {
        case decodeFailed
        case truncated
        case exceedsCap
    }

    static func sha256OfDecompressedContent(at path: URL, cap: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        guard let stream = ZSTD_createDStream() else { throw Error.decodeFailed }
        defer { ZSTD_freeDStream(stream) }

        var hasher = SHA256()
        var totalDecompressed = 0
        var outputBuffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var lastResult = 0
        var readAny = false

        while let chunk = try handle.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty {
            readAny = true
            try chunk.withUnsafeBytes { inputBytes in
                var input = ZSTD_inBuffer(src: inputBytes.baseAddress, size: inputBytes.count, pos: 0)
                var produced = 0
                // libzstd may still hold decoded bytes after consuming all
                // input, so keep draining until a call yields nothing.
                repeat {
                    try outputBuffer.withUnsafeMutableBytes { outputBytes in
                        var output = ZSTD_outBuffer(dst: outputBytes.baseAddress, size: outputBytes.count, pos: 0)
                        let consumedBefore = input.pos
                        let result = ZSTD_decompressStream(stream, &output, &input)
                        guard ZSTD_isError(result) == 0 else { throw Error.decodeFailed }
                        // An idle drain call reports the next frame's header
                        // hint, not the state of the frame just decoded.
                        if output.pos > 0 || input.pos > consumedBefore { lastResult = result }
                        totalDecompressed += output.pos
                        guard totalDecompressed <= cap else { throw Error.exceedsCap }
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: outputBytes.prefix(output.pos)))
                        produced = output.pos
                    }
                } while input.pos < input.size || produced > 0
            }
        }
        // 0 means the last frame was fully decoded and flushed.
        guard readAny, lastResult == 0 else { throw Error.truncated }

        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
