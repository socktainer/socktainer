import ContainerizationError
import ContainerizationOCI

/// On arm64 hosts, an image without an arm64 variant is pulled and run as amd64 under Rosetta.
enum RosettaFallback {
    /// Whether `error` from pulling or fetching `reference` for `requested` means the image
    /// has no variant for that platform, so the caller should retry with amd64.
    static func shouldRetryAsAmd64(_ error: Error, requested: Platform) -> Bool {
        guard requested.architecture == "arm64",
            let error = error as? ContainerizationError, error.isCode(.unsupported)
        else { return false }
        // Pulling: "image <digest> does not support required platforms".
        // Fetching an image already stored without the platform: "platform linux/arm64".
        return error.message.contains("does not support required platforms") || error.message.hasPrefix("platform ")
    }

    static func amd64(like platform: Platform) -> Platform {
        Platform(arch: "amd64", os: platform.os, variant: nil)
    }
}
