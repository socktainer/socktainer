import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import socktainer

@Suite("Engine storage configuration")
struct DirectVZEngineControllerTests {
    @Test("configuration rejects invalid resource values")
    func configurationValidation() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: DirectVZEngineControllerError.invalidCPUCount(0)) {
            _ = try DirectVZEngineConfiguration(
                stateDirectory: root.appendingPathComponent("state"),
                bindRoot: root,
                cpus: 0
            )
        }
        #expect(
            throws: DirectVZEngineControllerError.invalidMemory(
                DirectVZEngineConfiguration.minimumMemory - 1
            )
        ) {
            _ = try DirectVZEngineConfiguration(
                stateDirectory: root.appendingPathComponent("state"),
                bindRoot: root,
                memoryInBytes: DirectVZEngineConfiguration.minimumMemory - 1
            )
        }
        let minimumMemory = try DirectVZEngineConfiguration(
            stateDirectory: root.appendingPathComponent("minimum-memory"),
            bindRoot: root,
            memoryInBytes: 96 * 1024 * 1024
        )
        #expect(minimumMemory.memoryInBytes == 96 * 1024 * 1024)
        #expect(
            throws: DirectVZEngineControllerError.invalidDataDiskSize(
                DirectVZEngineConfiguration.minimumDataDiskSize - 1
            )
        ) {
            _ = try DirectVZEngineConfiguration(
                stateDirectory: root.appendingPathComponent("state"),
                bindRoot: root,
                dataDiskSize: DirectVZEngineConfiguration.minimumDataDiskSize - 1
            )
        }
    }

    @Test("data disk creation is sparse, valid, and idempotent")
    func dataDiskCreation() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let configuration = try DirectVZEngineConfiguration(
            stateDirectory: state,
            bindRoot: root,
            dataDiskSize: DirectVZEngineConfiguration.minimumDataDiskSize
        )

        try DirectVZEngineController.prepareDataDisk(configuration)
        let firstAttributes = try FileManager.default.attributesOfItem(
            atPath: configuration.dataDisk.path
        )
        _ = try EXT4.EXT4Reader(blockDevice: FilePath(configuration.dataDisk.path))
        try DirectVZEngineController.prepareDataDisk(configuration)
        let secondAttributes = try FileManager.default.attributesOfItem(
            atPath: configuration.dataDisk.path
        )

        let logicalSize = try #require(
            (firstAttributes[.size] as? NSNumber)?.uint64Value
        )
        let allocatedSize = try configuration.dataDisk.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey]
        ).totalFileAllocatedSize
        #expect(logicalSize >= DirectVZEngineConfiguration.minimumDataDiskSize)
        #expect(allocatedSize.map { UInt64($0) < logicalSize } == true)
        #expect(firstAttributes[.systemFileNumber] as? NSNumber == secondAttributes[.systemFileNumber] as? NSNumber)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "socktainer-direct-vz-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
