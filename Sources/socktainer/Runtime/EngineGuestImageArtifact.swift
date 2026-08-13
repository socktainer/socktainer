import Foundation

enum EngineMachineProvisioningError: Error, Equatable {
    case guestImageNotFound([String])
    case guestImageEmpty
}

struct EngineGuestImageArtifact: Sendable {
    let url: URL

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        var candidates: [URL] = []
        if let configured = environment["SOCKTAINER_GUEST_IMAGE"] {
            candidates.append(URL(fileURLWithPath: configured))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        candidates.append(
            executable.deletingLastPathComponent()
                .appendingPathComponent("../share/socktainer/socktainer-guest.oci.tar")
                .standardizedFileURL
        )
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Guest/out/socktainer-guest.oci.tar")
        )
        guard let artifact = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw EngineMachineProvisioningError.guestImageNotFound(candidates.map(\.path))
        }
        return Self(url: artifact)
    }
}
