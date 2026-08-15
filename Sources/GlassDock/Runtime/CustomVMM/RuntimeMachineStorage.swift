import ContainerizationEXT4
import Foundation
import SystemPackage

protocol RuntimeMachineStoragePreparing: Sendable {
    func prepareDataDisk(at url: URL) throws
}

struct FoundationRuntimeMachineStoragePreparer: RuntimeMachineStoragePreparing {
    func prepareDataDisk(at url: URL) throws {
        try RuntimeMachineStorage.prepareDataDisk(at: url)
    }
}

enum RuntimeMachineStorage {
    static let dataDiskSize: UInt64 = 1024 * 1024 * 1024

    static func prepareDataDisk(at url: URL, size: UInt64 = dataDiskSize) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: url.path) {
            do {
                let reader = try EXT4.EXT4Reader(blockDevice: FilePath(url.path))
                if reader.superBlock.featureCompat & 0x4 != 0,
                    reader.superBlock.journalInum == 8,
                    reader.superBlock.defaultMountOpts == 0x40
                {
                    return
                }
                throw RuntimeMachineStorageError.incompatibleDataDisk
            } catch RuntimeMachineStorageError.incompatibleDataDisk {
                let quarantine = url.deletingLastPathComponent()
                    .appendingPathComponent("data.ext4.incompatible-\(UUID().uuidString)")
                try fileManager.moveItem(at: url, to: quarantine)
            }
        }
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".data-\(UUID().uuidString).ext4")
        do {
            let formatter = try EXT4.Formatter(
                FilePath(staging.path),
                minDiskSize: size,
                journal: .init(defaultMode: .ordered)
            )
            try formatter.close()
            try fileManager.moveItem(at: staging, to: url)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}

private enum RuntimeMachineStorageError: Error {
    case incompatibleDataDisk
}
