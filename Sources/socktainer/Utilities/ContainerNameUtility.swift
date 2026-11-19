import CryptoKit
import Foundation

enum ContainerNameUtility {
    static let maxLength = 63

    static func sanitize(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let suffix = "-" + hashSuffix(name)
        let prefix = String(name.prefix(maxLength - suffix.count))
        return prefix + suffix
    }

    /// The first `length` lowercase hex characters of the SHA-256 of `input`.
    static func hashSuffix(_ input: String, length: Int = 12) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hashHex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hashHex.prefix(length))
    }

    /// `<first label of requested>.<random suffix>`. The guest hostname is the first label,
    /// capped at 63 chars (Linux/VZ hostname limit; longer values fail start with EINVAL).
    static func uniqueAttachmentHostname(requested: String) -> String {
        let label = sanitize(guestHostname(requested))
        return "\(label).\(UUID().uuidString.lowercased().prefix(12))"
    }

    /// The hostname Apple Container gives the guest for an attachment hostname.
    static func guestHostname(_ attachmentHostname: String) -> String {
        attachmentHostname.split(separator: ".", maxSplits: 1).first.map(String.init) ?? attachmentHostname
    }
}
