import ContainerResource
import Vapor

struct VolumeSyncModeKey: StorageKey {
    typealias Value = Filesystem.SyncMode
}

extension Filesystem.SyncMode {
    /// Label key used to persist per-volume sync mode across create → container-mount.
    static let socktainerLabel = "socktainer.volume.sync"

    /// Parses a sync mode from a string (case-insensitive).
    /// Returns nil for unrecognised values so callers can fall back to their default.
    init?(rawString: String) {
        switch rawString.lowercased() {
        case "nosync": self = .nosync
        case "fsync": self = .fsync
        case "full": self = .full
        default: return nil
        }
    }

    var rawString: String {
        switch self {
        case .nosync: "nosync"
        case .fsync: "fsync"
        case .full: "full"
        }
    }

    /// Resolves a sync mode from a CLI string, falling back to nosync and calling
    /// `warn` with a message when the value is unrecognised. Injectable for testing.
    static func resolve(
        from string: String,
        warn: (String) -> Void = { print($0) }
    ) -> Filesystem.SyncMode {
        if let mode = Filesystem.SyncMode(rawString: string) {
            return mode
        }
        warn("warning: unknown --volume-sync value '\(string)', falling back to nosync")
        return .nosync
    }
}
