import CryptoKit
import Foundation

enum ContainerNameUtility {
    static let maxLength = 64

    static func sanitize(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(name.utf8))
        let hashHex = digest.compactMap { String(format: "%02x", $0) }.joined()
        let suffix = "-" + hashHex.prefix(12)
        let prefix = String(name.prefix(maxLength - suffix.count))
        return prefix + suffix
    }
}
