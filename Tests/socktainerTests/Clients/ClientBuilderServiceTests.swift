import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Testing

@testable import socktainer

@Suite("ClientBuilderService.builderContainerConfiguration")
struct ClientBuilderServiceConfigurationTests {

    private func makeImageDescription() -> ImageDescription {
        ImageDescription(
            reference: "ghcr.io/apple/container-builder-shim/builder:0.12.0",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
    }

    @Test("Grants CAP_SYS_ADMIN so BuildKit's runc-native snapshotter can rbind-mount build contexts")
    func grantsCapSysAdmin() throws {
        let config = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: makeImageDescription(),
            imageEnv: nil,
            useRosetta: false,
            qemu: false,
            builderCPUs: 2,
            builderMemory: "2048MB",
            exportsMountPath: "/tmp/exports",
            networkId: "default",
            nameserver: "192.168.65.1"
        )
        #expect(config.capAdd == ["ALL"], "BuildKit's runc-native snapshotter needs CAP_SYS_ADMIN to rbind-mount build contexts — root alone is not sufficient (issue #260)")
    }

    @Test("Threads the builder id, network, and nameserver through to the resulting configuration")
    func threadsCoreIdentity() throws {
        let config = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: makeImageDescription(),
            imageEnv: ["PATH=/usr/bin"],
            useRosetta: true,
            qemu: false,
            builderCPUs: 4,
            builderMemory: "4096MB",
            exportsMountPath: "/tmp/exports",
            networkId: "mynet",
            nameserver: "192.168.65.1"
        )
        #expect(config.id == "buildkit")
        #expect(config.initProcess.environment == ["PATH=/usr/bin"])
        #expect(config.rosetta == true)
        #expect(config.networks.first?.network == "mynet")
        #expect(config.dns?.nameservers == ["192.168.65.1"])
    }

    @Test("--enable-qemu is derived solely from qemu, independent of useRosetta")
    func enableQemuIndependentOfRosetta() throws {
        // The Rosetta builder with the user's own rosetta support disabled (useRosetta:
        // false) must NOT also register QEMU binfmt handlers — these are mutually
        // exclusive in the shim, and this combination previously did exactly that by
        // deriving --enable-qemu from `!useRosetta` instead of the actual qemu flag.
        let rosettaBuilderConfig = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit",
            imageDescription: makeImageDescription(),
            imageEnv: nil,
            useRosetta: false,
            qemu: false,
            builderCPUs: 2,
            builderMemory: "2048MB",
            exportsMountPath: "/tmp/exports",
            networkId: "default",
            nameserver: "192.168.65.1"
        )
        #expect(!rosettaBuilderConfig.initProcess.arguments.contains("--enable-qemu"))
        #expect(rosettaBuilderConfig.rosetta == false)

        let qemuBuilderConfig = try ClientBuilderService.builderContainerConfiguration(
            builderContainerId: "buildkit-qemu",
            imageDescription: makeImageDescription(),
            imageEnv: nil,
            useRosetta: false,
            qemu: true,
            builderCPUs: 2,
            builderMemory: "2048MB",
            exportsMountPath: "/tmp/exports",
            networkId: "default",
            nameserver: "192.168.65.1"
        )
        #expect(qemuBuilderConfig.initProcess.arguments.contains("--enable-qemu"))
    }
}
