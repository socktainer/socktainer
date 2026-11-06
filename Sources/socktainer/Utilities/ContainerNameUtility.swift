import CryptoKit
import Foundation

enum ContainerNameUtility {
    static let maxLength = 63

    static func sanitize(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(name.utf8))
        let hashHex = digest.compactMap { String(format: "%02x", $0) }.joined()
        let suffix = "-" + hashHex.prefix(12)
        let prefix = String(name.prefix(maxLength - suffix.count))
        return prefix + suffix
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
