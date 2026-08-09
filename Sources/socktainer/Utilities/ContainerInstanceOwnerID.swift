import CryptoKit
import Foundation

/// Stable identity for durable Socktainer metadata scoped to one metadata
/// directory so daemon instances can scope recovery without a second manager.
enum ContainerInstanceOwnerID {
    static func forMetadataDirectory(_ directory: URL) -> String {
        SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
