import Compression
import CryptoKit
import Foundation

/// Streams a plain file into a gzip-compressed one. Apple's `Compression`
/// framework only speaks raw DEFLATE, so this builds the gzip container
/// (RFC 1952) by hand around it: a header, the DEFLATE stream, then a
/// CRC-32 + ISIZE trailer.
enum GzipStreamEncoder {
    enum Error: Swift.Error {
        case encodeFailed
    }

    struct Result {
        let compressedDigest: String
        let compressedSize: Int
        let uncompressedDigest: String
    }

    private static let gzipMagic: [UInt8] = [0x1f, 0x8b]
    private static let compressionMethodDeflate: UInt8 = 0x08
    private static let unsetFlags: UInt8 = 0x00
    private static let unsetModificationTime: [UInt8] = [0x00, 0x00, 0x00, 0x00]
    private static let unsetExtraFlags: UInt8 = 0x00
    private static let operatingSystemUnknown: UInt8 = 0xff
    private static let header = Data(
        gzipMagic + [compressionMethodDeflate, unsetFlags] + unsetModificationTime + [unsetExtraFlags, operatingSystemUnknown])

    static func compressFile(at sourcePath: URL, to destinationPath: URL) throws -> Result {
        guard FileManager.default.createFile(atPath: destinationPath.path, contents: nil) else {
            throw Error.encodeFailed
        }
        let sourceHandle = try FileHandle(forReadingFrom: sourcePath)
        defer { try? sourceHandle.close() }
        let destinationHandle = try FileHandle(forWritingTo: destinationPath)
        defer { try? destinationHandle.close() }

        try destinationHandle.write(contentsOf: header)
        let body = try encodeDeflateBody(from: sourceHandle, into: destinationHandle)
        try destinationHandle.write(contentsOf: trailer(crc: body.crc, uncompressedSize: body.uncompressedSize))

        let compressed = try FileHashing.sha256OfFile(at: destinationPath)
        return Result(compressedDigest: compressed.digest, compressedSize: compressed.size, uncompressedDigest: body.uncompressedDigest)
    }

    private static func encodeDeflateBody(
        from sourceHandle: FileHandle, into destinationHandle: FileHandle
    ) throws -> (uncompressedDigest: String, crc: UInt32, uncompressedSize: Int) {
        var uncompressedHasher = SHA256()
        var crc = CRC32.Incremental()
        var uncompressedSize = 0
        let chunkSize = CompressionStreamDriver.defaultChunkSize

        try CompressionStreamDriver.withStream(operation: COMPRESSION_STREAM_ENCODE, onError: { Error.encodeFailed }) { stream, placeholder in
            var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
            var status: compression_status = COMPRESSION_STATUS_OK

            while status != COMPRESSION_STATUS_END {
                let chunk = try sourceHandle.read(upToCount: chunkSize) ?? Data()
                let isFinalChunk = chunk.count < chunkSize
                uncompressedHasher.update(data: chunk)
                uncompressedSize += chunk.count
                chunk.withUnsafeBytes { crc.update($0) }

                status = try CompressionStreamDriver.process(
                    &stream, input: chunk, finalize: isFinalChunk, outputBuffer: &outputBuffer, placeholder: placeholder,
                    onError: { Error.encodeFailed },
                    onOutput: { produced in try destinationHandle.write(contentsOf: Data(produced)) })

                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw Error.encodeFailed
                }
            }
        }

        return (uncompressedHasher.finalize().hexString, crc.value, uncompressedSize)
    }

    private static func trailer(crc: UInt32, uncompressedSize: Int) -> Data {
        var trailer = Data()
        withUnsafeBytes(of: crc.littleEndian) { trailer.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: uncompressedSize).littleEndian) { trailer.append(contentsOf: $0) }
        return trailer
    }
}
