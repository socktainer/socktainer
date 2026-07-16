import ContainerResource

/// Single source of truth for detecting a "volume not found" condition.
///
/// The framework's `ClientVolume.inspect` throws a typed
/// `VolumeError.volumeNotFound`, but that type does not survive Apple
/// Container's XPC boundary: the service flattens it into a
/// `ContainerizationError(.invalidArgument, message: "volume '<name>' not found")`
/// (see `XPCServer`). So both the typed error (defensive, for in-process
/// paths) and the flattened message must be recognized.
enum VolumeNotFound {
    static func matches(_ error: any Error) -> Bool {
        if let volumeError = error as? VolumeError, case .volumeNotFound = volumeError {
            return true
        }
        let description = String(describing: error)
        return description.contains("not found") || description.contains("No such volume")
    }
}
