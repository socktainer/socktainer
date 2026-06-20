import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage
import Testing

@testable import socktainer

/// Tests for VolumeImageCleaner — removing `/lost+found` from fresh EXT4 volumes.
struct VolumeImageCleanerTests {
    let tempDir: URL
    let logger = Logger(label: "test.volume-clean")

    init() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vol-clean-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// Formats a fresh EXT4 image the way Apple Container does — which always
    /// creates `/lost+found` at the root.
    private func freshExt4Image(name: String = "vol.img") throws -> URL {
        let path = tempDir.appendingPathComponent(name)
        let formatter = try EXT4.Formatter(FilePath(path.path), blockSize: 4096, minDiskSize: 16 * 1024 * 1024)
        try formatter.close()
        return path
    }

    @Test("A freshly-formatted EXT4 image contains /lost+found (baseline)")
    func freshImageHasLostFound() throws {
        let img = try freshExt4Image()
        let editor = try EXT4Editor(devicePath: FilePath(img.path))
        #expect(editor.exists(path: "/lost+found") == true)
    }

    @Test("removeLostFound deletes /lost+found and leaves a readable filesystem")
    func removesLostFound() throws {
        let img = try freshExt4Image()
        VolumeImageCleaner.removeLostFound(imagePath: img.path, logger: logger)

        let editor = try EXT4Editor(devicePath: FilePath(img.path))
        #expect(editor.exists(path: "/lost+found") == false)
        // Root remains a valid, readable ext4 filesystem.
        #expect(editor.exists(path: "/") == true)
    }

    @Test("Skips a path that is not a regular file (never wipes a directory)")
    func skipsNonRegularFile() {
        // Must not throw or touch anything when handed a directory.
        VolumeImageCleaner.removeLostFound(imagePath: tempDir.path, logger: logger)
        #expect(FileManager.default.fileExists(atPath: tempDir.path))
    }

    @Test("Skips a missing path")
    func skipsMissingPath() {
        VolumeImageCleaner.removeLostFound(imagePath: tempDir.appendingPathComponent("nope.img").path, logger: logger)
    }

    @Test("Skips a regular file that is not an EXT4 image (never reformats it)")
    func skipsNonExt4File() throws {
        let junk = tempDir.appendingPathComponent("junk.img")
        try Data(repeating: 0, count: 1024 * 1024).write(to: junk)  // 1 MB of zeros — not ext4
        VolumeImageCleaner.removeLostFound(imagePath: junk.path, logger: logger)
        // The file must be left untouched — not reformatted into a valid ext4 fs.
        #expect((try? EXT4Editor(devicePath: FilePath(junk.path))) == nil)
    }

    @Test("Is idempotent — safe to call on a volume already without /lost+found")
    func idempotentOnCleanVolume() throws {
        let img = try freshExt4Image()
        VolumeImageCleaner.removeLostFound(imagePath: img.path, logger: logger)
        // Second call must not wipe the volume — /lost+found is already gone.
        VolumeImageCleaner.removeLostFound(imagePath: img.path, logger: logger)
        let editor = try EXT4Editor(devicePath: FilePath(img.path))
        #expect(editor.exists(path: "/") == true)
        #expect(editor.exists(path: "/lost+found") == false)
    }

    @Test("Opt-out via env var and per-volume label")
    func optOut() {
        #expect(VolumeImageCleaner.isEnabled(labels: [:], environment: ["SOCKTAINER_CLEAN_VOLUMES": "false"]) == false)
        #expect(VolumeImageCleaner.isEnabled(labels: [:], environment: ["SOCKTAINER_CLEAN_VOLUMES": "FALSE"]) == false)
        #expect(VolumeImageCleaner.isEnabled(labels: ["socktainer.clean-volumes": "false"], environment: [:]) == false)
        #expect(VolumeImageCleaner.isEnabled(labels: [:], environment: [:]) == true)
        #expect(VolumeImageCleaner.isEnabled(labels: ["socktainer.clean-volumes": "true"], environment: [:]) == true)
    }
}
