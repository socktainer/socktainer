import Foundation

/// Compile-time boundary for Apple Container APIs that are intentionally version locked.
///
/// Apple Container's XPC schemas and public Swift initializers can change between patch
/// releases. Keeping those calls here makes an SDK upgrade a small, reviewable change
/// instead of scattering version-specific arguments throughout Docker route handling.
enum AppleContainerCompatibility {
    static let sdkVersion = getAppleContainerVersion()

    static func isCompatible(apiServerVersion: String) -> Bool {
        semanticVersion(in: apiServerVersion) == sdkVersion
    }

    static func semanticVersion(in value: String) -> String? {
        let pattern = "\\b\\d+\\.\\d+\\.\\d+\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: value.utf16.count)
        guard let match = regex.firstMatch(in: value, range: range),
            let swiftRange = Range(match.range, in: value)
        else { return nil }
        return String(value[swiftRange])
    }
}
