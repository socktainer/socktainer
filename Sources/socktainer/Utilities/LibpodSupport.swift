import Foundation

/// Podman (`/libpod/*`) API support is on by default. Setting
/// `SOCKTAINER_DISABLE_LIBPOD` to a truthy value (`1`, `true`, `yes`, `on`) opts out: none of
/// the libpod routes are registered, and `/_ping` stops advertising `Libpod-API-Version`, so
/// socktainer behaves as a plain Docker Engine API endpoint.
enum LibpodSupport {
    static let disableEnvironmentVariable = "SOCKTAINER_DISABLE_LIBPOD"

    /// The libpod API version advertised on `/_ping` and in `/libpod/version`.
    static let apiVersion = "5.0.0"

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = environment[disableEnvironmentVariable] else { return true }
        return !["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
