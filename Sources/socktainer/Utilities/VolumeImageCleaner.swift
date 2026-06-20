import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

/// Removes `/lost+found` from the EXT4 image backing a named volume.
///
/// Apple Container always creates `/lost+found` at the volume root, which
/// causes Postgres's `initdb` to reject the directory as non-empty. Named
/// volumes are always mounted at their root, so `/lost+found` is always at
/// the top of every mount — the EXT4 reformat is idempotent (no-op when
/// already absent) and safe for all images.
/// Best-effort: failures are logged and never propagate to the caller.
enum VolumeImageCleaner {
    static let optOutLabel = "socktainer.clean-volumes"
    static let optOutEnvVar = "SOCKTAINER_CLEAN_VOLUMES"

    /// Returns true when `PGDATA` is set in `mergedEnv` (any value), which
    /// reliably identifies a Postgres container regardless of the actual path.
    /// Named volumes are always mounted at their root, so any EXT4 named volume
    /// used by a Postgres container may contain `/lost+found` at the mount root.
    static func isPostgresDataVolume(mergedEnv: [String]) -> Bool {
        mergedEnv.contains(where: { $0.hasPrefix("PGDATA=") })
    }

    /// Returns false when opted out via `SOCKTAINER_CLEAN_VOLUMES=false` or
    /// the `socktainer.clean-volumes=false` volume label.
    static func isEnabled(
        labels: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[optOutEnvVar]?.lowercased() == "false" { return false }
        if labels[optOutLabel]?.lowercased() == "false" { return false }
        return true
    }

    /// Reformats the EXT4 block image at `imagePath`, removing `/lost+found`.
    /// Skips non-regular-files, non-EXT4 images, and images already without it.
    static func removeLostFound(imagePath: String, logger: Logger) {
        let fm = FileManager.default

        // Guard against a directory-backed mount point (never a block image).
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: imagePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            logger.warning("[volume-clean] skip: \(imagePath) is not a regular file")
            return
        }

        // Use the real file size, not the optional volume metadata.
        guard let attributes = try? fm.attributesOfItem(atPath: imagePath),
            let size = (attributes[.size] as? NSNumber)?.uint64Value, size >= 4 * 1024 * 1024
        else {
            logger.warning("[volume-clean] skip: image too small to be a valid EXT4 filesystem: \(imagePath)")
            return
        }

        let path = FilePath(imagePath)

        // Idempotency + safety: skip if not EXT4 or already clean.
        do {
            let probe = try EXT4Editor(devicePath: path)
            guard probe.exists(path: "/lost+found") else {
                logger.info("[volume-clean] \(imagePath) has no /lost+found; nothing to do")
                return
            }
        } catch {
            logger.warning("[volume-clean] skip: \(imagePath) is not a readable EXT4 image: \(error)")
            return
        }

        do {
            // blockSize 4096, no journal — mirrors Apple's own ContainerManager.
            let formatter = try EXT4.Formatter(path, blockSize: 4096, minDiskSize: size)
            try formatter.unlink(path: FilePath("/lost+found"))
            try formatter.close()
        } catch {
            logger.warning("[volume-clean] reformat failed for \(imagePath): \(error)")
            return
        }

        // Verify.
        do {
            let editor = try EXT4Editor(devicePath: path)
            if editor.exists(path: "/lost+found") {
                logger.warning("[volume-clean] /lost+found still present after reformat: \(imagePath)")
            } else {
                logger.info("[volume-clean] removed /lost+found from \(imagePath)")
            }
        } catch {
            logger.warning("[volume-clean] post-reformat verification failed for \(imagePath): \(error)")
        }
    }
}
