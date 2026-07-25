import ContainerResource
import ContainerizationError

/// Single source of truth for detecting a "volume not found" condition.
///
/// The framework's `ClientVolume.inspect` throws a typed
/// `VolumeError.volumeNotFound`, but that type does not survive Apple
/// Container's XPC boundary: the service flattens it into a
/// `ContainerizationError(.invalidArgument, message: "volume '<name>' not found")`
/// (see `XPCServer`). Match only these two well-defined shapes so an unrelated
/// backend failure is never misread as a missing volume (which would otherwise
/// turn a 500 into a 404, or be silently swallowed under `force`).
enum VolumeNotFound {
    static func matches(_ error: any Error) -> Bool {
        // In-process paths throw the framework's typed error directly.
        if let volumeError = error as? VolumeError, case .volumeNotFound = volumeError {
            return true
        }
        // Across the XPC boundary the typed error arrives as a
        // ContainerizationError: either with the `.notFound` code, or flattened
        // into `.invalidArgument` carrying the "volume '<name>' not found"
        // message. Scope the message check to a volume-not-found payload so
        // other invalid-argument or storage errors are not caught.
        if let containerError = error as? ContainerizationError {
            if containerError.code == .notFound {
                return true
            }
            let message = containerError.message
            return message.contains("volume '") && message.contains("not found")
        }
        return false
    }
}
