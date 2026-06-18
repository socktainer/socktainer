import ContainerAPIClient
import ContainerPersistence
import Testing

@testable import socktainer

/// Verifies that ContainerSystemConfig overrides are honoured by the apple/container
/// normalizeReference logic that all image operations ultimately go through.
@Suite("SystemConfig propagation")
struct SystemConfigPropagationTests {

    @Test("default registry.domain resolves unqualified references via docker.io")
    func defaultRegistryResolvesToDockerIO() throws {
        let config = ContainerSystemConfig()

        let normalized = try ClientImage.normalizeReference("ubuntu", containerSystemConfig: config)

        #expect(normalized.hasPrefix("docker.io/") || normalized.hasPrefix("registry-1.docker.io/"))
    }

    @Test("custom registry.domain is prepended to unqualified image references")
    func customRegistryDomainPropagated() throws {
        let config = ContainerSystemConfig(registry: .init(domain: "ghcr.io"))

        let normalized = try ClientImage.normalizeReference("ubuntu", containerSystemConfig: config)

        #expect(normalized.hasPrefix("ghcr.io/"))
        #expect(!normalized.contains("docker.io"))
    }

    @Test("fully-qualified references are not modified by registry.domain override")
    func fullyQualifiedReferenceUnchanged() throws {
        let config = ContainerSystemConfig(registry: .init(domain: "ghcr.io"))

        let normalized = try ClientImage.normalizeReference(
            "docker.io/library/ubuntu:latest", containerSystemConfig: config)

        #expect(normalized.hasPrefix("docker.io/"))
    }

    @Test("tag is preserved when custom registry.domain is applied")
    func tagPreservedWithCustomRegistry() throws {
        let config = ContainerSystemConfig(registry: .init(domain: "ghcr.io"))

        let normalized = try ClientImage.normalizeReference("ubuntu:22.04", containerSystemConfig: config)

        #expect(normalized.hasPrefix("ghcr.io/"))
        #expect(normalized.contains("22.04"))
    }

    @Test("malformed reference throws an error")
    func malformedReferenceThrows() {
        #expect(throws: (any Error).self) {
            try ClientImage.normalizeReference("://invalid", containerSystemConfig: ContainerSystemConfig())
        }
    }
}
