import CFilteredStream
import Darwin
import Foundation

/// Fixed-buffer access to the complete bytes beneath a gzip, bzip2, or xz
/// filter. Libarchive's raw format deliberately does not parse the inner tar,
/// so callers receive every byte exactly as Docker's decompression filter does:
/// tar headers, PAX records, padding, and payload all remain intact.
///
/// This is kept separate from `ArchiveReader`, whose public API exposes entry
/// payloads rather than the raw filtered stream. Staging is bounded before each
/// write and partial output is removed on decode failure, cap rejection, I/O
/// failure, or task cancellation.
enum FilteredStreamDecoder {
    /// A normal `xz -9` stream needs about 65 MiB to decode. This ceiling
    /// leaves room for legitimate high-compression Docker layers while
    /// rejecting attacker-selected multi-gigabyte LZMA2 dictionaries before
    /// liblzma allocates them.
    static let defaultMaximumDecoderMemoryBytes: UInt64 = 256 * 1024 * 1024

    enum Compression {
        case gzip
        case bzip2
        case xz

        fileprivate var code: glassdock_filtered_stream_codec {
            switch self {
            case .gzip: GLASSDOCK_FILTER_GZIP
            case .bzip2: GLASSDOCK_FILTER_BZIP2
            case .xz: GLASSDOCK_FILTER_XZ
            }
        }
    }

    enum Error: Swift.Error, Equatable {
        case initializationFailed
        case invalidStream
        case memoryLimitExceeded
        case exceedsCap
    }

    @discardableResult
    static func decompress(
        source: URL,
        destination: URL,
        compression: Compression,
        maxBytes: Int64,
        maxDecoderMemoryBytes: UInt64 = defaultMaximumDecoderMemoryBytes
    ) throws -> Int64 {
        guard maxBytes >= 0 else { throw Error.exceedsCap }
        guard maxDecoderMemoryBytes > 0 else {
            throw Error.initializationFailed
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        guard
            let stream = glassdock_filtered_stream_open(
                sourceHandle.fileDescriptor,
                compression.code,
                maxDecoderMemoryBytes
            )
        else {
            throw Error.initializationFailed
        }
        defer { glassdock_filtered_stream_close(stream) }

        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationDescriptor >= 0 else {
            throw Error.initializationFailed
        }
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )

        var completed = false
        defer {
            try? destinationHandle.close()
            if !completed {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var totalBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                glassdock_filtered_stream_read(
                    stream,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            guard bytesRead >= 0 else {
                if glassdock_filtered_stream_last_error(stream)
                    == GLASSDOCK_FILTERED_STREAM_ERROR_MEMORY_LIMIT
                {
                    throw Error.memoryLimitExceeded
                }
                throw Error.invalidStream
            }
            guard bytesRead > 0 else { break }

            let count = Int64(bytesRead)
            guard count <= maxBytes - totalBytes else {
                throw Error.exceedsCap
            }
            try destinationHandle.write(
                contentsOf: Data(buffer.prefix(Int(bytesRead)))
            )
            totalBytes += count
        }

        try Task.checkCancellation()
        completed = true
        return totalBytes
    }
}
