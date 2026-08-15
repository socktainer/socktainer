import Foundation
import libzstd

enum ZstdTestSupport {
    enum Error: Swift.Error {
        case compressionFailed
    }

    static func compress(source: URL, destination: URL) throws {
        let sourceData = try Data(contentsOf: source)
        let capacity = ZSTD_compressBound(sourceData.count)
        var compressed = Data(count: capacity)
        let compressedSize = try compressed.withUnsafeMutableBytes {
            destinationBytes in
            try sourceData.withUnsafeBytes { sourceBytes in
                let result = ZSTD_compress(
                    destinationBytes.baseAddress,
                    destinationBytes.count,
                    sourceBytes.baseAddress,
                    sourceBytes.count,
                    3
                )
                guard ZSTD_isError(result) == 0 else {
                    throw Error.compressionFailed
                }
                return result
            }
        }
        compressed.removeSubrange(compressedSize..<compressed.count)
        try compressed.write(to: destination)
    }
}
