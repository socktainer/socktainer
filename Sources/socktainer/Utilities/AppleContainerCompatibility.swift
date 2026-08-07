import ContainerBuild
import ContainerPersistence
import ContainerizationOCI
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

    struct BuildRequest {
        let buildID: String
        let contentStore: ContentStore
        let buildArgs: [String]
        let secrets: [String: Data]
        let ssh: String
        let contextDir: String
        let dockerfile: Data
        let dockerignore: Data?
        let labels: [String]
        let noCache: Bool
        let platforms: [Platform]
        let tags: [String]
        let target: String
        let quiet: Bool
        let exports: [Builder.BuildExport]
        let cacheIn: [String]
        let cacheOut: [String]
        let pull: Bool
        let containerSystemConfig: ContainerSystemConfig
    }

    static func makeBuildConfig(_ request: BuildRequest) -> Builder.BuildConfig {
        Builder.BuildConfig(
            buildID: request.buildID,
            contentStore: request.contentStore,
            buildArgs: request.buildArgs,
            secrets: request.secrets,
            ssh: request.ssh,
            contextDir: request.contextDir,
            dockerfile: request.dockerfile,
            dockerignore: request.dockerignore,
            labels: request.labels,
            noCache: request.noCache,
            platforms: request.platforms,
            terminal: nil,
            tags: request.tags,
            target: request.target,
            quiet: request.quiet,
            exports: request.exports,
            cacheIn: request.cacheIn,
            cacheOut: request.cacheOut,
            pull: request.pull,
            containerSystemConfig: request.containerSystemConfig
        )
    }
}
