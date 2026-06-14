import ContainerizationOCI
import Foundation

enum AppleContainerSnapshotResolver {
    static func unpackedSize(appSupportURL: URL, descriptor: Descriptor) -> Int64 {
        let snapshotDirectory =
            appSupportURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(descriptor.digest.trimmingDigestPrefix, isDirectory: true)

        guard FileManager.default.fileExists(atPath: snapshotDirectory.path) else {
            return 0
        }

        return Int64((try? FileManager.default.directorySize(dir: snapshotDirectory)) ?? 0)
    }
}

extension FileManager {
    fileprivate func directorySize(dir: URL) throws -> UInt64 {
        var size: UInt64 = 0
        let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey]

        guard
            let enumerator = self.enumerator(
                at: dir,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                let fileSize = resourceValues.totalFileAllocatedSize
            {
                size += UInt64(fileSize)
            }
        }

        return size
    }
}
