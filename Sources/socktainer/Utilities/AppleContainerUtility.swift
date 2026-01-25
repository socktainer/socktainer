import ContainerAPIClient
import Containerization
import Foundation

public func getLinuxDefaultKernelName() async throws -> String {
    let kernel = try await ClientKernel.getDefaultKernel(for: SystemPlatform.current)
    let pathString = kernel.path.path
    let components = pathString.split(separator: "/")
    return components.last.map(String.init) ?? pathString
}

public func stripSubnetFromIP(_ ipAddress: String?) -> String? {
    guard let ipAddress = ipAddress else { return nil }
    return ipAddress.components(separatedBy: "/").first
}

/// Utility for checking Apple Container daemon version compatibility
public struct AppleContainerVersionCheck {

    /// Extracts a semantic version (e.g., 0.6.0) from a longer version string
    private static func extractSemver(from text: String) -> String? {
        // Look for the first occurrence of X.Y.Z
        let pattern = "\\b\\d+\\.\\d+\\.\\d+\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        if let range = Range(match.range, in: text) {
            return String(text[range])
        }
        return nil
    }

    /// Error types for version checking
    public enum VersionCheckError: Error, LocalizedError {
        case incompatibleVersion(detected: String, expected: String)
        case versionDetectionFailed(String)
        case xpcConnectionError
        case notStartedError

        public var errorDescription: String? {
            switch self {
            case .incompatibleVersion(let detected, let expected):
                return
                    "Apple Container version mismatch: detected \(detected) but this socktainer binary requires \(expected). This version incompatibility will cause XPC connection errors. Skip the check using --no-check-compatibility flag."
            case .versionDetectionFailed(let reason):
                return "Failed to detect Apple Container version: \(reason)"
            case .xpcConnectionError:
                return "XPC connection error detected. This usually indicates an incompatible Apple Container version."
            case .notStartedError:
                return "Ensure container system service has been started with `container system start`."
            }
        }

    }

    /// Checks if the installed Apple Container version is compatible
    public static func checkCompatibility() async throws {
        do {
            // Attempt to get version from Apple Container daemon
            let healthCheck = try await ClientHealthCheck.ping(timeout: .seconds(2))
            let serverVersionFull = healthCheck.apiServerVersion
            let serverVersion = extractSemver(from: serverVersionFull) ?? serverVersionFull

            // Check if client and server versions are compatible
            let requiredVersion = getAppleContainerVersion()
            if requiredVersion != serverVersion {
                throw VersionCheckError.incompatibleVersion(detected: serverVersion, expected: requiredVersion)
            }

            // Log the detected versions for debugging
            print("✅ Apple Container versions match: client \(requiredVersion) == server \(serverVersion)")

        } catch let error as VersionCheckError {
            throw error
        } catch {
            // Check for XPC connection issues which indicate version incompatibility
            if error.localizedDescription.contains("XPC connection") || error.localizedDescription.contains("Connection interrupted") {
                throw VersionCheckError.xpcConnectionError
            }
            if error.localizedDescription.contains("The operation couldn’t be completed") {
                throw VersionCheckError.notStartedError
            }

            // Other errors are version detection failures
            throw VersionCheckError.versionDetectionFailed(error.localizedDescription)
        }
    }

    /// Performs compatibility check with user-friendly output and exit if it fails
    public static func performCompatibilityCheck() async {
        do {
            try await checkCompatibility()
            print("✅ Apple Container compatibility check passed")
        } catch let error as VersionCheckError {
            print("❌ Apple Container compatibility check failed:")
            print("   Error: \(error.localizedDescription)")
            exit(1)
        } catch {
            print("⚠️  Warning: Could not verify Apple Container compatibility: \(error)")
        }
    }

}
