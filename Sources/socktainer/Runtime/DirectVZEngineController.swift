import ContainerizationEXT4
import Foundation
import SystemPackage

enum DirectVZEngineControllerError: Error, Equatable {
    case invalidIdentifier
    case invalidCPUCount(Int)
    case invalidMemory(UInt64)
    case invalidDataDiskSize(UInt64)
    case pathMustBeAbsolute(String)
    case bindRootNotDirectory(String)
    case unsupportedInitialFilesystem
    case interfaceUnavailable
}

/// Static inputs for the one direct Virtualization.framework engine VM.
struct DirectVZEngineConfiguration: Sendable, Equatable {
    static let minimumMemory: UInt64 = 96 * 1024 * 1024
    static let minimumDataDiskSize: UInt64 = 64 * 1024 * 1024

    let id: String
    let stateDirectory: URL
    let bindRoot: URL
    let dataDiskSize: UInt64
    let cpus: Int
    let memoryInBytes: UInt64

    let dataMountPath = "/var/lib/containerd"
    let bindDeviceMountPath = "/run/socktainer-host"

    init(
        id: String = "socktainer-engine",
        stateDirectory: URL,
        bindRoot: URL,
        dataDiskSize: UInt64 = 64 * 1024 * 1024 * 1024,
        cpus: Int = 4,
        memoryInBytes: UInt64 = 4 * 1024 * 1024 * 1024
    ) throws {
        guard !id.isEmpty else { throw DirectVZEngineControllerError.invalidIdentifier }
        guard cpus > 0 else { throw DirectVZEngineControllerError.invalidCPUCount(cpus) }
        guard memoryInBytes >= Self.minimumMemory else {
            throw DirectVZEngineControllerError.invalidMemory(memoryInBytes)
        }
        guard dataDiskSize >= Self.minimumDataDiskSize else {
            throw DirectVZEngineControllerError.invalidDataDiskSize(dataDiskSize)
        }
        for url in [stateDirectory, bindRoot] where !url.path.hasPrefix("/") {
            throw DirectVZEngineControllerError.pathMustBeAbsolute(url.path)
        }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: bindRoot.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue
        else {
            throw DirectVZEngineControllerError.bindRootNotDirectory(bindRoot.path)
        }
        self.id = id
        self.stateDirectory = stateDirectory.standardizedFileURL
        self.bindRoot = bindRoot.standardizedFileURL
        self.dataDiskSize = dataDiskSize
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }

    var dataDisk: URL {
        stateDirectory.appendingPathComponent("data.ext4", isDirectory: false)
    }

}

/// Shared storage preparation used by the single LinuxPod engine substrate.
enum DirectVZEngineController {
    static func prepareDataDisk(_ configuration: DirectVZEngineConfiguration) throws {
        if FileManager.default.fileExists(atPath: configuration.dataDisk.path) {
            do {
                _ = try EXT4.EXT4Reader(
                    blockDevice: FilePath(configuration.dataDisk.path)
                )
                return
            } catch {
                let quarantine = configuration.stateDirectory.appendingPathComponent(
                    "data.ext4.corrupt-\(UUID().uuidString)"
                )
                try FileManager.default.moveItem(
                    at: configuration.dataDisk,
                    to: quarantine
                )
            }
        }
        let staging = configuration.stateDirectory.appendingPathComponent(
            ".data-\(UUID().uuidString).ext4"
        )
        do {
            let formatter = try EXT4.Formatter(
                FilePath(staging.path),
                minDiskSize: configuration.dataDiskSize
            )
            try formatter.close()
            try FileManager.default.moveItem(
                at: staging,
                to: configuration.dataDisk
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
