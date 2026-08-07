import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("StoppedContainerBundleMaterializer")
struct StoppedContainerBundleMaterializerTests {
    @Test("materializes Apple's deferred bundle for a never-started container")
    func materializesDeferredBundle() async throws {
        let fixture = try BundleMaterializationFixture(containerID: "buildx_buildkit_test")
        defer { fixture.cleanUp() }

        let rootfs = try await StoppedContainerBundleMaterializer.shared.materializeIfNeeded(
            containerID: fixture.containerID,
            appSupportPath: fixture.appSupportPath
        )

        #expect(FileManager.default.fileExists(atPath: rootfs.path))
        #expect(try Data(contentsOf: rootfs) == Data("image-rootfs".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.containerPath.appendingPathComponent("config.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.containerPath.appendingPathComponent("initfs.ext4").path))
    }

    @Test("an already-materialized rootfs is an idempotent no-op")
    func existingRootfsIsNotReplaced() async throws {
        let fixture = try BundleMaterializationFixture(containerID: "existing")
        defer { fixture.cleanUp() }

        let rootfs = try await StoppedContainerBundleMaterializer.shared.materializeIfNeeded(
            containerID: fixture.containerID,
            appSupportPath: fixture.appSupportPath
        )
        try Data("container-changes".utf8).write(to: rootfs)

        _ = try await StoppedContainerBundleMaterializer.shared.materializeIfNeeded(
            containerID: fixture.containerID,
            appSupportPath: fixture.appSupportPath
        )

        #expect(try Data(contentsOf: rootfs) == Data("container-changes".utf8))
    }

    @Test("a corrupt runtime hand-off reports a bounded archive error")
    func corruptRuntimeConfiguration() async throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let containerPath = appSupport.appendingPathComponent("containers/broken")
        try FileManager.default.createDirectory(at: containerPath, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: containerPath.appendingPathComponent("runtime-configuration.json"))

        do {
            _ = try await StoppedContainerBundleMaterializer.shared.materializeIfNeeded(
                containerID: "broken",
                appSupportPath: appSupport
            )
            Issue.record("corrupt runtime configuration must fail")
        } catch let error as ClientArchiveError {
            guard case .operationFailed(let message) = error else {
                Issue.record("expected operationFailed, got \(error)")
                return
            }
            #expect(message.contains("broken"))
        }
    }
}

private struct BundleMaterializationFixture {
    let containerID: String
    let appSupportPath: URL
    let containerPath: URL

    init(containerID: String) throws {
        self.containerID = containerID
        appSupportPath = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-materialize-\(UUID().uuidString)")
        containerPath = appSupportPath.appendingPathComponent("containers/\(containerID)")
        try FileManager.default.createDirectory(at: containerPath, withIntermediateDirectories: true)

        let sources = appSupportPath.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let initfs = sources.appendingPathComponent("initfs.ext4")
        let kernelPath = sources.appendingPathComponent("kernel.bin")
        let imageRootfs = sources.appendingPathComponent("rootfs.ext4")
        try Data("init".utf8).write(to: initfs)
        try Data("kernel".utf8).write(to: kernelPath)
        try Data("image-rootfs".utf8).write(to: imageRootfs)

        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:" + String(repeating: "a", count: 64),
            size: 1
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: []
        )
        let container = ContainerConfiguration(
            id: containerID,
            image: ImageDescription(reference: "example:latest", descriptor: descriptor),
            process: process
        )
        let runtime = RuntimeConfiguration(
            path: containerPath,
            initialFilesystem: .block(format: "ext4", source: initfs.path, destination: "/", options: ["ro"]),
            kernel: Kernel(path: kernelPath, platform: .linuxArm),
            containerConfiguration: container,
            containerRootFilesystem: .block(format: "ext4", source: imageRootfs.path, destination: "/", options: []),
            options: .default,
            runtimeData: nil
        )
        try JSONEncoder().encode(runtime).write(to: containerPath.appendingPathComponent("runtime-configuration.json"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupportPath)
    }
}
