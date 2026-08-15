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
///
/// Concatenated gzip members (`cat a.gz b.gz > combined.gz`, valid per RFC
/// 1952 §2.2) are decompressed as one continuous logical stream, matching
/// both real `gunzip` and Go's `compress/gzip` (which defaults
/// `Multistream: true`) — moby's own decompression path this mirrors.
enum GzipStreamDecoder {
    enum Error: Swift.Error, Equatable {
        case invalidHeader
        case decodeFailed
        case exceedsCap
    }

    private static let chunkSize = CompressionStreamDriver.defaultChunkSize
    private static let trailerSize = 8  // CRC32 + ISIZE, per member

    static func sha256OfDecompressedContent(at path: URL, cap: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let source = ChunkedByteSource(handle: handle)

        var hasher = SHA256()
        var totalDecompressed = 0
        var decodedAnyMember = false

        while try source.hasMoreBytes() {
            try decodeOneMember(path: path, source: source, into: &hasher, totalDecompressed: &totalDecompressed, cap: cap)
            decodedAnyMember = true
            try source.consume(trailerSize)  // CRC32 + ISIZE
        }
        guard decodedAnyMember else { throw Error.invalidHeader }

        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func decodeOneMember(
        path: URL, source: ChunkedByteSource, into hasher: inout SHA256, totalDecompressed: inout Int, cap: Int
    ) throws {
        let headerLength = try readHeaderLength(source)
        try source.consume(headerLength)
        let memberOffset = try source.currentFileOffset()

        try CompressionStreamDriver.withStream(operation: COMPRESSION_STREAM_DECODE, onError: { Error.decodeFailed }) { stream, placeholder in
            var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
            var status: compression_status = COMPRESSION_STATUS_OK

            while status != COMPRESSION_STATUS_END {
                let chunkStartOffset = try source.currentFileOffset()
                let sourceChunk = try source.read(upTo: chunkSize)
                let isLastAvailableChunk = try sourceChunk.count < chunkSize && !source.hasMoreBytes()

                status = try CompressionStreamDriver.process(
                    &stream, input: sourceChunk, finalize: isLastAvailableChunk, outputBuffer: &outputBuffer, placeholder: placeholder,
                    onError: { Error.decodeFailed },
                    onOutput: { produced in
                        hasher.update(bufferPointer: produced)
                        totalDecompressed += produced.count
                        guard totalDecompressed <= cap else { throw Error.exceedsCap }
                    })

                if status == COMPRESSION_STATUS_END {
                    // `compression_stream` reports the whole fed chunk as
                    // consumed once it hits the DEFLATE end marker, even when
                    // this chunk also holds bytes past it (this member's
                    // trailer, and potentially a next member) — unlike
                    // zlib's `inflate()`, which tracks the exact boundary via
                    // `avail_in`. Resolving that ambiguity means re-decoding
                    // everything fed to this member so far, once per
                    // binary-search trial, so it's only worth doing when
                    // there's a reason to suspect it's needed: either the
                    // file still has more content after this chunk (an
                    // unambiguous "there's definitely another member" —
                    // cheap regardless of size, since a lone huge member has
                    // nothing left to disambiguate), or this was the
                    // member's very first read (several small members can
                    // land in one chunk together, which `hasMoreBytes()`
                    // alone would miss — but priorLength is 0 here, so
                    // re-decoding is cheap too). A large member with nothing
                    // after it skips this entirely.
                    let priorLength = chunkStartOffset - memberOffset
                    if try source.hasMoreBytes() || priorLength == 0 {
                        let memberLength = try findMemberLength(
                            path: path, memberOffset: memberOffset, priorLength: priorLength,
                            finalChunkLength: sourceChunk.count, cap: cap)
                        // The binary search's success signal (does decoding
                        // reach END) is trustworthy once `process` no longer
                        // exits early, but a corrupt or adversarial input is
                        // still worth guarding against with an independent
                        // check: what immediately follows the found
                        // boundary's 8-byte trailer must be either true EOF
                        // or another gzip header — never silently trust a
                        // boundary that lands somewhere else.
                        guard try boundaryLooksValid(path: path, at: memberOffset + memberLength + trailerSize) else {
                            throw Error.decodeFailed
                        }
                        let boundaryWithinChunk = memberLength - priorLength
                        source.unread(sourceChunk.suffix(from: sourceChunk.startIndex + boundaryWithinChunk))
                    }
                } else {
                    guard !isLastAvailableChunk else { throw Error.decodeFailed }
                }
            }
        }
    }

    /// True when `offset` is at true end-of-file, or the two bytes there are
    /// a gzip magic number — the only two shapes a genuine member boundary
    /// can take.
    private static func boundaryLooksValid(path: URL, at offset: Int) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let magic = try handle.read(upToCount: 2) ?? Data()
        return magic.isEmpty || magic.elementsEqual([0x1f, 0x8b])
    }

    /// Binary-searches for the shortest prefix of this member's compressed
    /// bytes (starting at `memberOffset`) that decodes to completion —
    /// re-reading from disk for each trial rather than keeping already-fed
    /// chunks in memory, so a large ambiguous member can't reintroduce the
    /// unbounded-memory problem this decoder exists to avoid (bounded,
    /// if redundant, disk I/O instead).
    private static func findMemberLength(path: URL, memberOffset: Int, priorLength: Int, finalChunkLength: Int, cap: Int) throws -> Int {
        var lower = priorLength
        var upper = priorLength + finalChunkLength
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if try memberDecodes(path: path, memberOffset: memberOffset, length: mid, cap: cap) {
                upper = mid
            } else {
                lower = mid + 1
            }
        }
        return lower
    }

    private static func memberDecodes(path: URL, memberOffset: Int, length: Int, cap: Int) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(memberOffset))

        return try CompressionStreamDriver.withStream(operation: COMPRESSION_STREAM_DECODE, onError: { Error.decodeFailed }) { stream, placeholder in
            var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
            var status: compression_status = COMPRESSION_STATUS_OK
            var remaining = length
            var totalProduced = 0

            while status == COMPRESSION_STATUS_OK {
                let wanted = min(chunkSize, remaining)
                let chunk = wanted > 0 ? (try handle.read(upToCount: wanted) ?? Data()) : Data()
                remaining -= chunk.count
                do {
                    status = try CompressionStreamDriver.process(
                        &stream, input: chunk, finalize: remaining == 0, outputBuffer: &outputBuffer, placeholder: placeholder,
                        onError: { Error.decodeFailed },
                        onOutput: { produced in
                            totalProduced += produced.count
                            guard totalProduced <= cap else { throw Error.exceedsCap }
                        })
                } catch {
                    return false
                }
                if remaining == 0 { break }
            }
            return status == COMPRESSION_STATUS_END
        }
    }

    /// Reads just enough to find where the DEFLATE payload starts, honoring
    /// the optional FEXTRA/FNAME/FCOMMENT/FHCRC fields (RFC 1952 §2.3) rather
    /// than assuming the fixed 10-byte minimum.
    private static func readHeaderLength(_ source: ChunkedByteSource) throws -> Int {
        var probeSize = 1024
        while true {
            let probe = try source.peek(upTo: probeSize)
            if let length = try? parseGzipHeaderLength(probe) { return length }
            guard probe.count == probeSize, probeSize < (1 << 20) else { throw Error.invalidHeader }
            probeSize *= 2
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

/// A forward-only byte source backed by a `FileHandle`, supporting the
/// look-ahead (`peek`) and give-back (`unread`) operations gzip's
/// multi-member framing needs: the header parser must see bytes before
/// committing to consuming them, and `compression_stream_process` routinely
/// under-consumes a chunk (leaving the next member's trailer/header inside
/// it) without ever reading the whole file into memory at once.
private final class ChunkedByteSource {
    private let handle: FileHandle
    private var buffer = Data()
    private var bufferStartOffset = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    func hasMoreBytes() throws -> Bool {
        try fill(upTo: 1)
        return !buffer.isEmpty
    }

    /// The absolute file offset of the next unread byte.
    func currentFileOffset() throws -> Int {
        bufferStartOffset
    }

    func peek(upTo count: Int) throws -> Data {
        try fill(upTo: count)
        return buffer.prefix(count)
    }

    func consume(_ count: Int) throws {
        try fill(upTo: count)
        let removed = min(count, buffer.count)
        buffer.removeFirst(removed)
        bufferStartOffset += removed
    }

    func read(upTo count: Int) throws -> Data {
        try fill(upTo: count)
        let chunk = buffer.prefix(count)
        buffer.removeFirst(chunk.count)
        bufferStartOffset += chunk.count
        return chunk
    }

    /// Restores bytes `compression_stream_process` didn't consume — always
    /// the unconsumed suffix of what was just handed to it via `read` — so
    /// the trailer (and any following member's header) is seen again.
    func unread(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        buffer = bytes + buffer
        bufferStartOffset -= bytes.count
    }

    private func fill(upTo target: Int) throws {
        while buffer.count < target {
            guard let more = try handle.read(upToCount: max(target - buffer.count, 1 << 16)), !more.isEmpty else {
                return
            }
            buffer.append(more)
        }
    }
}
