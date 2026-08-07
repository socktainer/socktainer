import Darwin
import Foundation
import libzstd

/// Quota-aware zstd decompression for outer Docker archive compression.
/// Containerization 0.40.1's URL-based `ArchiveReader` expands zstd into an
/// unbounded temporary file, while the system libarchive it wraps cannot add a
/// zstd read filter directly. This driver uses the same pinned libzstd package
/// in fixed-size buffers, checks cancellation between chunks, and stops before
/// writing beyond the caller's archive-stream ceiling.
enum ZstdStreamDecoder {
    enum Error: Swift.Error, Equatable {
        case initializationFailed
        case invalidStream
        case exceedsCap
    }

    /// Limits a malicious frame's decompression window to 128 MiB in addition
    /// to bounding emitted bytes. This is zstd's conventional default maximum
    /// and is ample for ordinary Docker/OCI tar compression.
    private static let maxWindowLog: Int32 = 27

    @discardableResult
    static func decompress(
        source: URL,
        destination: URL,
        maxBytes: Int64
    ) throws -> Int64 {
        guard maxBytes >= 0 else { throw Error.exceedsCap }
        guard let stream = ZSTD_createDStream() else {
            throw Error.initializationFailed
        }
        defer { ZSTD_freeDStream(stream) }

        let windowResult = ZSTD_DCtx_setParameter(
            stream,
            ZSTD_d_windowLogMax,
            maxWindowLog
        )
        guard ZSTD_isError(windowResult) == 0 else {
            throw Error.initializationFailed
        }
        let initializationResult = ZSTD_initDStream(stream)
        guard ZSTD_isError(initializationResult) == 0 else {
            throw Error.initializationFailed
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        let destinationDescriptor = open(
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

        let inputSize = max(Int(ZSTD_DStreamInSize()), 1)
        let outputSize = max(Int(ZSTD_DStreamOutSize()), 1)
        var output = [UInt8](repeating: 0, count: outputSize)
        var totalBytes: Int64 = 0
        var lastResult = initializationResult
        var decodedFrame = false

        while true {
            try Task.checkCancellation()
            let inputData = try sourceHandle.read(upToCount: inputSize) ?? Data()
            guard !inputData.isEmpty else { break }

            try inputData.withUnsafeBytes { inputBytes in
                var input = ZSTD_inBuffer(
                    src: inputBytes.baseAddress,
                    size: inputBytes.count,
                    pos: 0
                )
                while input.pos < input.size {
                    try Task.checkCancellation()
                    let previousInputPosition = input.pos
                    let result = try output.withUnsafeMutableBytes {
                        outputBytes -> size_t in
                        var outputBuffer = ZSTD_outBuffer(
                            dst: outputBytes.baseAddress,
                            size: outputBytes.count,
                            pos: 0
                        )
                        let result = ZSTD_decompressStream(
                            stream,
                            &outputBuffer,
                            &input
                        )
                        guard ZSTD_isError(result) == 0 else {
                            throw Error.invalidStream
                        }
                        if outputBuffer.pos > 0 {
                            guard
                                let outputBaseAddress =
                                    outputBytes.baseAddress
                            else {
                                throw Error.initializationFailed
                            }
                            let emitted = Int64(outputBuffer.pos)
                            guard emitted <= maxBytes - totalBytes else {
                                throw Error.exceedsCap
                            }
                            try destinationHandle.write(
                                contentsOf: Data(
                                    bytes: outputBaseAddress,
                                    count: outputBuffer.pos
                                )
                            )
                            totalBytes += emitted
                        }
                        return result
                    }
                    lastResult = result
                    if result == 0 {
                        decodedFrame = true
                    }
                    guard input.pos > previousInputPosition || result == 0 else {
                        throw Error.invalidStream
                    }
                }
            }
        }

        guard decodedFrame, lastResult == 0 else {
            throw Error.invalidStream
        }
        try Task.checkCancellation()
        completed = true
        return totalBytes
    }
}
