import ContainerResource
import CryptoKit
import Foundation

/// Docker clients expect container IDs to be 64-character hex digests and
/// freely truncate them — `docker ps` shows only the first 12 characters,
/// even with `-q` or `--format '{{.ID}}'`, and feeds them back into
/// `inspect`/`exec`/`stop`. Apple container identifies containers by name,
/// so socktainer derives a stable Docker-shaped ID from the native ID and
/// resolves hex references back to native IDs.
enum DockerContainerID {
    /// Returns the Docker-shaped ID for a container: the SHA-256 digest of
    /// its native ID and creation date, hex-encoded (64 lowercase
    /// characters). Deriving instead of storing keeps the mapping stable
    /// across restarts and covers containers created outside socktainer.
    /// Including the creation date preserves Docker's semantics that
    /// recreating a container under the same name yields a new ID.
    static func hexId(for container: ContainerSnapshot) -> String {
        hexId(nativeId: container.id, createdAt: AppleContainerTimestampResolver.containerCreationDate(container))
    }

    static func hexId(nativeId: String, createdAt: Date?) -> String {
        var input = nativeId
        if let createdAt {
            input += "\n\(createdAt.timeIntervalSince1970)"
        }
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    enum Resolution: Equatable {
        case match(String)
        case ambiguous([String])
        case none
    }

    /// Resolves a client-supplied reference — a native ID/name, a full hex
    /// ID, or a hex ID prefix — against `(nativeId, hexId)` entries. Mirrors
    /// the Docker daemon's behavior of rejecting prefixes that match more
    /// than one container.
    static func resolve(reference: String, entries: [(nativeId: String, hexId: String)]) -> Resolution {
        if entries.contains(where: { $0.nativeId == reference }) {
            return .match(reference)
        }
        // Only lowercase hex strings can be (truncated) Docker IDs.
        guard !reference.isEmpty, reference.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return .none
        }
        let matches = entries.filter { $0.hexId.hasPrefix(reference) }.map(\.nativeId)
        switch matches.count {
        case 0: return .none
        case 1: return .match(matches[0])
        default: return .ambiguous(matches)
        }
    }
}
