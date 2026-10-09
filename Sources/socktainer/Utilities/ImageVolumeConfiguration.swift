import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging

/// Apple's typed OCI config omits Docker's Volumes, Healthcheck and ExposedPorts fields. Decode
/// them from the original config blob rather than re-encoding the lossy OCI model.
struct ImageVolumeConfiguration: Decodable {
    struct Config: Decodable {
        let Volumes: [String: [String: String]]?
        let Healthcheck: HealthcheckConfig?
        let ExposedPorts: [String: [String: String]]?
    }
    let config: Config?

    static func read(image: ClientImage, platform: Platform) async throws -> Config? {
        let manifest = try await image.manifest(for: platform)
        guard let content = try await RemoteContentStoreClient().get(digest: manifest.config.digest) else {
            throw ContainerizationError(.notFound, message: "image config blob missing: \(manifest.config.digest)")
        }
        let decoded: ImageVolumeConfiguration = try content.decode()
        return decoded.config
    }

    /// Inspect already tolerates incomplete platform metadata. Preserve that
    /// behavior for these optional fields, but log the failure rather than hiding it.
    /// Container creation uses the strict reader above and must not skip volumes.
    static func readForInspect<T>(
        logger: Logger, read: () async throws -> T?
    ) async -> T? {
        do {
            return try await read()
        } catch {
            logger.warning("Could not read image config: \(error)")
            return nil
        }
    }

    /// Explicit mounts override declarations at the same destination. A parent
    /// mount does not override a nested image volume (matching Docker).
    static func mounts(
        imagePaths: [String], requestPaths: [String], explicit: [VolumeOrFilesystem]
    ) throws -> [VolumeOrFilesystem] {
        let occupied = Set(
            explicit.map { item in
                switch item {
                case .filesystem(let fs): normalize(fs.destination)
                case .volume(let volume): normalize(volume.destination)
                }
            })
        var paths = Set<String>()
        for path in imagePaths + requestPaths {
            guard path.hasPrefix("/"), !path.contains("\0"), normalize(path) != "/" else {
                throw ContainerizationError(.invalidArgument, message: "invalid volume destination: \(path)")
            }
            paths.insert(normalize(path))
        }
        return paths.subtracting(occupied).sorted().map { path in
            .volume(
                ParsedVolume(
                    name: VolumeStorage.generateAnonymousVolumeName(), destination: path, isAnonymous: true))
        }
    }

    private static func normalize(_ path: String) -> String {
        // Guest paths are Linux paths; do not resolve symlinks on the Mac host.
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else if part != "." {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
