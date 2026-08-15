import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import GlassDock

@Suite("Custom VMM storage")
struct RuntimeMachineStorageTests {
    @Test("creates and reuses one valid sparse data disk")
    func createsAndReusesDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-vmm-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appendingPathComponent("data.ext4")

        try RuntimeMachineStorage.prepareDataDisk(at: disk, size: 64 * 1024 * 1024)
        let first = try FileManager.default.attributesOfItem(atPath: disk.path)[.creationDate] as? Date
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(disk.path))
        #expect(reader.superBlock.featureCompat & 0x4 != 0)
        #expect(reader.superBlock.journalInum == 8)
        #expect(reader.superBlock.defaultMountOpts == 0x40)

        try RuntimeMachineStorage.prepareDataDisk(at: disk, size: 64 * 1024 * 1024)

        #expect(try FileManager.default.attributesOfItem(atPath: disk.path)[.creationDate] as? Date == first)
    }

    @Test("replaces a valid data disk that has no ordered journal")
    func replacesUnjournaledDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-vmm-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("data.ext4")
        let formatter = try EXT4.Formatter(
            FilePath(disk.path),
            minDiskSize: 64 * 1024 * 1024
        )
        try formatter.close()

        try RuntimeMachineStorage.prepareDataDisk(at: disk, size: 64 * 1024 * 1024)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(disk.path))
        #expect(reader.superBlock.featureCompat & 0x4 != 0)
        #expect(reader.superBlock.journalInum == 8)
        #expect(reader.superBlock.defaultMountOpts == 0x40)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("data.ext4.incompatible-") }
        #expect(quarantined.count == 1)
    }

    @Test("preserves invalid storage and fails startup")
    func preservesInvalidDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-vmm-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("data.ext4")
        try Data("invalid".utf8).write(to: disk)

        #expect(throws: (any Error).self) {
            try RuntimeMachineStorage.prepareDataDisk(at: disk, size: 64 * 1024 * 1024)
        }

        #expect(try Data(contentsOf: disk) == Data("invalid".utf8))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("data.ext4.incompatible-") }
        #expect(quarantined.isEmpty)
    }
}
