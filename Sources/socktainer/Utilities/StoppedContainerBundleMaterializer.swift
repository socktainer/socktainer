import ContainerResource
import ContainerRuntimeClient
import Containerization
import Foundation

/// Serializes lazy bundle creation across concurrent Docker archive requests.
/// `Bundle.create` uses copy-on-write clones on macOS, so this preserves Apple's
/// normal per-container writable-rootfs model rather than copying image data.
actor StoppedContainerBundleMaterializer {
    static let shared = StoppedContainerBundleMaterializer()

    private let fileManager = FileManager.default

    /// Returns the expected rootfs URL. If Apple already materialized it, this
    /// is a no-op. A missing runtime hand-off is left for the caller to report as
    /// Docker's normal "rootfs not found" error (for legacy/corrupt resources).
    func materializeIfNeeded(containerID: String, appSupportPath: URL) throws -> URL {
        let containerPath =
            appSupportPath
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(containerID, isDirectory: true)
        let rootfsPath = containerPath.appendingPathComponent("rootfs.ext4")
        guard !fileManager.fileExists(atPath: rootfsPath.path) else {
            return rootfsPath
        }

        let runtimeConfigurationPath = containerPath.appendingPathComponent("runtime-configuration.json")
        guard fileManager.fileExists(atPath: runtimeConfigurationPath.path) else {
            return rootfsPath
        }

        do {
            // Use Apple's public decoder as the compatibility boundary. If the
            // persisted schema changes with a future container release, its own
            // RuntimeConfiguration implementation remains authoritative.
            let runtime = try RuntimeConfiguration.readRuntimeConfiguration(from: containerPath)
            _ = try Bundle.create(
                path: runtime.path,
                initialFilesystem: runtime.initialFilesystem,
                kernel: runtime.kernel,
                containerConfiguration: runtime.containerConfiguration,
                containerRootFilesystem: runtime.containerRootFilesystem,
                options: runtime.options
            )
            return rootfsPath
        } catch {
            throw ClientArchiveError.operationFailed(
                message: "failed to materialize rootfs for stopped container \(containerID): \(error)"
            )
        }
    }
}
