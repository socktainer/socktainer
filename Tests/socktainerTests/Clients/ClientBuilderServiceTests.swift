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
}
