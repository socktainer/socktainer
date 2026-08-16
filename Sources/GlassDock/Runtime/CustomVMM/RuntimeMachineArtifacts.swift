import Foundation

struct RuntimeMachineArtifacts: Sendable, Equatable {
    let helper: URL
    let library: URL
    let gvproxy: URL
    let kernel: URL
    let rootDisk: URL

    static func locate(
        executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
        repositoryRoot: URL? = nil
    ) throws -> Self {
        let executableDirectory = executable.deletingLastPathComponent()
        let installedPrefix =
            executableDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let installedShare =
            installedPrefix
            .appendingPathComponent("share/glassdock", isDirectory: true)
        let roots = [
            repositoryRoot
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ]
        let candidates =
            [
                Self(
                    helper: executableDirectory.appendingPathComponent("glassdock-vmm"),
                    library: executableDirectory.appendingPathComponent("libkrun.1.dylib"),
                    gvproxy: executableDirectory.appendingPathComponent("gvproxy"),
                    kernel: installedShare.appendingPathComponent("glassdock-vmlinux"),
                    rootDisk: installedShare.appendingPathComponent("glassdock-root.ext4")
                )
            ]
            + roots.map {
                Self(
                    helper: $0.appendingPathComponent("VMM/out/glassdock-vmm"),
                    library: $0.appendingPathComponent("VMM/out/libkrun.1.dylib"),
                    gvproxy: $0.appendingPathComponent("VMM/out/gvproxy"),
                    kernel: $0.appendingPathComponent("Guest/out/glassdock-vmlinux"),
                    rootDisk: $0.appendingPathComponent("Guest/out/glassdock-root.ext4")
                )
            }
        guard let artifacts = candidates.first(where: \Self.isUsable) else {
            throw RuntimeMachineError.invalidConfiguration(
                "custom VMM artifacts are missing; expected helper, libkrun, gvproxy, kernel, and root disk"
            )
        }
        return artifacts
    }

    private var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: helper.path)
            && FileManager.default.isReadableFile(atPath: library.path)
            && FileManager.default.isExecutableFile(atPath: gvproxy.path)
            && FileManager.default.isReadableFile(atPath: kernel.path)
            && FileManager.default.isReadableFile(atPath: rootDisk.path)
    }
}
