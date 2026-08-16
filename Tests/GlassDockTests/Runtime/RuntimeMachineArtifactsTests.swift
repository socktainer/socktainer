import Foundation
import Testing

@testable import GlassDock

@Suite("Custom VMM artifact discovery")
struct RuntimeMachineArtifactsTests {
    @Test("locates private helpers and shared guest assets in an installed release")
    func locatesInstalledLayout() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "glassdock-installed-artifacts-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let files = [
            "libexec/glassdock/glassdock",
            "libexec/glassdock/glassdock-vmm",
            "libexec/glassdock/libkrun.1.dylib",
            "libexec/glassdock/gvproxy",
            "share/glassdock/glassdock-vmlinux",
            "share/glassdock/glassdock-root.ext4",
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data("fixture".utf8))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }

        let artifacts = try RuntimeMachineArtifacts.locate(
            executable: root.appendingPathComponent("libexec/glassdock/glassdock"),
            repositoryRoot: root.appendingPathComponent("not-a-repository")
        )
        #expect(artifacts.helper == root.appendingPathComponent("libexec/glassdock/glassdock-vmm"))
        #expect(artifacts.kernel == root.appendingPathComponent("share/glassdock/glassdock-vmlinux"))
    }

    @Test("uses one complete repository artifact set")
    func repositoryArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-vmm-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [
            "VMM/out/glassdock-vmm",
            "VMM/out/libkrun.1.dylib",
            "VMM/out/gvproxy",
            "Guest/out/glassdock-vmlinux",
            "Guest/out/glassdock-root.ext4",
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
            executable: URL(fileURLWithPath: "/missing/bin/glassdock"),
            repositoryRoot: root
        )

        #expect(artifacts.helper == root.appendingPathComponent("VMM/out/glassdock-vmm"))
        #expect(artifacts.gvproxy == root.appendingPathComponent("VMM/out/gvproxy"))
        #expect(artifacts.kernel == root.appendingPathComponent("Guest/out/glassdock-vmlinux"))
    }

    @Test("rejects an artifact set without the helper's gvproxy sibling")
    func missingGVProxy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-vmm-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [
            "VMM/out/glassdock-vmm",
            "VMM/out/libkrun.1.dylib",
            "Guest/out/glassdock-vmlinux",
            "Guest/out/glassdock-root.ext4",
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
                executable: URL(fileURLWithPath: "/missing/bin/glassdock"),
                repositoryRoot: root
            )
        }
    }

    @Test("rejects a partial artifact set")
    func partialArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-vmm-artifacts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("VMM/out"),
            withIntermediateDirectories: true
        )
        #expect(
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("VMM/out/glassdock-vmm").path,
                contents: Data([0])
            )
        )

        #expect(throws: RuntimeMachineError.self) {
            _ = try RuntimeMachineArtifacts.locate(
                executable: URL(fileURLWithPath: "/missing/bin/glassdock"),
                repositoryRoot: root
            )
        }
    }
}
