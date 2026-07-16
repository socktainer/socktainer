import Compression
import CryptoKit
import Foundation

/// Streams a gzip file's decompressed content through Apple's system
/// `Compression` framework rather than materializing it in memory —
/// `DataCompression` (used for storing/producing gzip layers elsewhere in
/// this codebase) only exposes whole-buffer `gzip()`/`gunzip()`, so a small,
/// highly-compressible malicious file could otherwise expand to gigabytes
/// before anything could check its size. Both the compressed input and the
/// decompressed output are read/produced in fixed-size chunks; exceeding
/// `cap` aborts mid-stream instead of after the fact.
enum GzipStreamDecoder {
    enum Error: Swift.Error, Equatable {
        case invalidHeader
        case decodeFailed
        case exceedsCap
    }

    private static let chunkSize = 1 << 20

    static func sha256OfDecompressedContent(at path: URL, cap: Int) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let fileSize = attributes[.size] as? UInt64 else {
            throw Error.invalidHeader
        }

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }

        let headerLength = try readHeaderLength(handle)
        // The final 8 bytes (CRC32 + ISIZE) are a trailer, not part of the
        // DEFLATE stream Compression's decoder consumes.
        let payloadEnd = fileSize - 8
        guard payloadEnd >= headerLength else { throw Error.invalidHeader }
        try handle.seek(toOffset: UInt64(headerLength))

        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: placeholder, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Error.decodeFailed
        }
        defer { compression_stream_destroy(&stream) }

        var hasher = SHA256()
        var totalDecompressed = 0
        var remaining = Int(payloadEnd) - headerLength
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let wantedBytes = min(chunkSize, remaining)
            let sourceChunk = wantedBytes > 0 ? (try handle.read(upToCount: wantedBytes) ?? Data()) : Data()
            remaining -= sourceChunk.count
            let isFinalChunk = remaining == 0

            var status: compression_status = COMPRESSION_STATUS_OK
            try sourceChunk.withUnsafeBytes { (sourceRaw: UnsafeRawBufferPointer) in
                stream.src_ptr = sourceRaw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
                stream.src_size = sourceChunk.count

                repeat {
                    try outputBuffer.withUnsafeMutableBufferPointer { outputPtr in
                        stream.dst_ptr = outputPtr.baseAddress!
                        stream.dst_size = chunkSize
                        let flags: Int32 = isFinalChunk ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                        status = compression_stream_process(&stream, flags)
                        guard status != COMPRESSION_STATUS_ERROR else { throw Error.decodeFailed }

                        let produced = chunkSize - stream.dst_size
                        guard produced > 0 else { return }
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: outputPtr.baseAddress, count: produced))
                        totalDecompressed += produced
                        guard totalDecompressed <= cap else { throw Error.exceedsCap }
                    }
                } while status == COMPRESSION_STATUS_OK && (stream.src_size > 0 || isFinalChunk)
            }

            if isFinalChunk { break }
        }

        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Reads just enough of the file to find where the DEFLATE payload
    /// starts, honoring the optional FEXTRA/FNAME/FCOMMENT/FHCRC fields
    /// (RFC 1952 §2.3) rather than assuming the fixed 10-byte minimum.
    private static func readHeaderLength(_ handle: FileHandle) throws -> Int {
        // Comfortably covers a FNAME/FCOMMENT-bearing header in practice;
        // re-read with a larger window in the rare case a name/comment
        // field runs past it.
        var probe = try handle.read(upToCount: 1024) ?? Data()
        while true {
            if let length = try? parseGzipHeaderLength(probe) { return length }
            guard probe.count < (1 << 20) else { throw Error.invalidHeader }
            guard let more = try handle.read(upToCount: probe.count), !more.isEmpty else {
                throw Error.invalidHeader
            }
            probe.append(more)
        }
    }

    private static func parseGzipHeaderLength(_ data: Data) throws -> Int {
        guard data.count >= 10, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
            throw Error.invalidHeader
        }
        let flags = data[data.startIndex + 3]
        var offset = 10

        if flags & 0x04 != 0 {  // FEXTRA
            guard data.count >= offset + 2 else { throw Error.invalidHeader }
            let extraLength = Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { offset = try skipNullTerminated(data, from: offset) }  // FNAME
        if flags & 0x10 != 0 { offset = try skipNullTerminated(data, from: offset) }  // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC

        guard data.count > offset else { throw Error.invalidHeader }
        return offset
    }

    private static func skipNullTerminated(_ data: Data, from start: Int) throws -> Int {
        var offset = start
        while true {
            guard offset < data.count else { throw Error.invalidHeader }
            offset += 1
            if data[data.startIndex + offset - 1] == 0 { return offset }
        }
    }
}
