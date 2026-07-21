import CryptoKit
import Foundation

enum FileHashing {
    private static let chunkSize = 1 << 20

    static func sha256OfFile(at url: URL) throws -> (digest: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        return (hasher.finalize().hexString, size)
    }
}

extension SHA256Digest {
    var hexString: String {
        compactMap { String(format: "%02x", $0) }.joined()
    }
}
