import Compression
import Foundation

/// Shared low-level driver for Apple's system `compression_stream` API, used
/// by both `GzipStreamDecoder` and `GzipStreamEncoder` so the one genuinely
/// tricky part — knowing when to stop calling `compression_stream_process`
/// — is written and verified once.
enum CompressionStreamDriver {
    private static let chunkSize = 1 << 20

    static var defaultChunkSize: Int { chunkSize }

    /// `compression_stream`'s pointer fields are non-optional, so `init`
    /// needs *some* valid value before `process` ever assigns a real buffer;
    /// centralizing setup/teardown here means a stream can never outlive its
    /// placeholder or leak either one.
    static func withStream<T>(
        operation: compression_stream_operation, onError: () -> Swift.Error,
        _ body: (inout compression_stream, UnsafeMutablePointer<UInt8>) throws -> T
    ) throws -> T {
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: placeholder, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw onError()
        }
        defer { compression_stream_destroy(&stream) }
        return try body(&stream, placeholder)
    }

    /// Feeds `input` into `stream`, invoking `onOutput` with each produced
    /// chunk (never accumulated), and returns the resulting status.
    static func process(
        _ stream: inout compression_stream, input: Data, finalize: Bool, outputBuffer: inout [UInt8],
        placeholder: UnsafeMutablePointer<UInt8>, onError: () -> Swift.Error, onOutput: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> compression_status {
        var status: compression_status = COMPRESSION_STATUS_OK
        try input.withUnsafeBytes { (sourceRaw: UnsafeRawBufferPointer) in
            stream.src_ptr = sourceRaw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
            stream.src_size = input.count

            var producedFullBuffer = false
            repeat {
                try outputBuffer.withUnsafeMutableBufferPointer { outputPtr in
                    stream.dst_ptr = outputPtr.baseAddress!
                    stream.dst_size = outputPtr.count
                    let flags: Int32 = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    status = compression_stream_process(&stream, flags)
                    guard status != COMPRESSION_STATUS_ERROR else { throw onError() }

                    let produced = outputPtr.count - stream.dst_size
                    producedFullBuffer = produced == outputPtr.count
                    guard produced > 0 else { return }
                    try onOutput(UnsafeRawBufferPointer(start: outputPtr.baseAddress, count: produced))
                }
                // `finalize` forces another pass even with zero input left: the
                // trailing flush takes several such calls to reach END, and
                // stopping at the first would leave `status` stuck at OK.
            } while status == COMPRESSION_STATUS_OK && (finalize || stream.src_size > 0 || producedFullBuffer)
        }
        return status
    }
}
