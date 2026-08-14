import Foundation
import Testing

@testable import socktainer

@Suite("Custom VMM artifact discovery")
struct RuntimeMachineArtifactsTests {
    @Test("uses one complete repository artifact set")
    func repositoryArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-vmm-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [
            "VMM/out/socktainer-vmm",
            "VMM/out/libkrun.1.dylib",
            "VMM/out/gvproxy",
            "Guest/out/socktainer-vmlinux",
            "Guest/out/socktainer-root.ext4",
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data([0])))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let artifacts = try RuntimeMachineArtifacts.locate(
            executable: URL(fileURLWithPath: "/missing/bin/socktainer"),
            repositoryRoot: root
        )

        #expect(artifacts.helper == root.appendingPathComponent("VMM/out/socktainer-vmm"))
        #expect(artifacts.gvproxy == root.appendingPathComponent("VMM/out/gvproxy"))
        #expect(artifacts.kernel == root.appendingPathComponent("Guest/out/socktainer-vmlinux"))
    }

    @Test("rejects an artifact set without the helper's gvproxy sibling")
    func missingGVProxy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-vmm-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [
            "VMM/out/socktainer-vmm",
            "VMM/out/libkrun.1.dylib",
            "Guest/out/socktainer-vmlinux",
            "Guest/out/socktainer-root.ext4",
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data([0])))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        #expect(throws: RuntimeMachineError.self) {
            _ = try RuntimeMachineArtifacts.locate(
                executable: URL(fileURLWithPath: "/missing/bin/socktainer"),
                repositoryRoot: root
            )
        }
    }

    @Test("rejects a partial artifact set")
    func partialArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-vmm-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("VMM/out"),
            withIntermediateDirectories: true
        )
        #expect(
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("VMM/out/socktainer-vmm").path,
                contents: Data([0])
            )
        )

        #expect(throws: RuntimeMachineError.self) {
            _ = try RuntimeMachineArtifacts.locate(
                executable: URL(fileURLWithPath: "/missing/bin/socktainer"),
                repositoryRoot: root
            )
        }
    }
}
