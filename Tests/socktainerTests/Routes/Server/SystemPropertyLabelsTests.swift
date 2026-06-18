import ContainerPersistence
import ContainerizationExtras
import Foundation
import Testing

@testable import socktainer

@Suite("InfoRoute.systemPropertyLabels")
struct SystemPropertyLabelsTests {

    @Test("Produces all 8 expected label keys with default config")
    func defaultConfigHasAllKeys() {
        let labels = InfoRoute.systemPropertyLabels(config: ContainerSystemConfig())
        let keySet = Set(labels.map { $0.components(separatedBy: "=").first ?? "" })
        #expect(
            keySet == [
                "build.rosetta", "dns.domain", "image.builder", "image.init",
                "kernel.binaryPath", "kernel.url", "network.subnet", "registry.domain",
            ])
    }

    @Test("build.rosetta reflects the Bool value", arguments: [true, false])
    func buildRosettaValue(rosetta: Bool) {
        let config = ContainerSystemConfig(build: .init(rosetta: rosetta))
        #expect(InfoRoute.systemPropertyLabels(config: config).contains("build.rosetta=\(rosetta)"))
    }

    @Test("dns.domain shows *undefined* when nil")
    func dnsDomainNil() {
        let config = ContainerSystemConfig(dns: .init(domain: nil))
        #expect(InfoRoute.systemPropertyLabels(config: config).contains("dns.domain=*undefined*"))
    }

    @Test("dns.domain shows the value when set")
    func dnsDomainSet() {
        let config = ContainerSystemConfig(dns: .init(domain: "containers.local"))
        #expect(InfoRoute.systemPropertyLabels(config: config).contains("dns.domain=containers.local"))
    }

    @Test("network.subnet shows *undefined* when nil")
    func networkSubnetNil() {
        let config = ContainerSystemConfig(network: .init(subnet: nil))
        #expect(InfoRoute.systemPropertyLabels(config: config).contains("network.subnet=*undefined*"))
    }

    @Test("network.subnet shows CIDR notation when set")
    func networkSubnetSet() throws {
        let subnet = try CIDRv4("192.168.100.0/24")
        let config = ContainerSystemConfig(network: .init(subnet: subnet))
        #expect(
            InfoRoute.systemPropertyLabels(config: config).contains("network.subnet=192.168.100.0/24"))
    }

    @Test("registry.domain reflects a configured value")
    func registryDomain() {
        let config = ContainerSystemConfig(registry: .init(domain: "ghcr.io"))
        #expect(InfoRoute.systemPropertyLabels(config: config).contains("registry.domain=ghcr.io"))
    }

    @Test("image.builder reflects a custom value")
    func imageBuilderCustom() {
        let config = ContainerSystemConfig(build: .init(image: "my-builder:v1"))
        #expect(InfoRoute.systemPropertyLabels(config: config).contains("image.builder=my-builder:v1"))
    }

    @Test("image.init reflects a custom value")
    func imageInitCustom() {
        let config = ContainerSystemConfig(vminit: .init(image: "my-vminit:v1"))
        #expect(InfoRoute.systemPropertyLabels(config: config).contains("image.init=my-vminit:v1"))
    }

    @Test("kernel.binaryPath reflects a custom value")
    func kernelBinaryPathCustom() {
        let config = ContainerSystemConfig(kernel: .init(binaryPath: "opt/my/kernel/vmlinux"))
        #expect(
            InfoRoute.systemPropertyLabels(config: config).contains(
                "kernel.binaryPath=opt/my/kernel/vmlinux"))
    }

    @Test("kernel.url uses absoluteString serialisation")
    func kernelURLAbsoluteString() {
        let url = URL(string: "https://example.com/kernel.tar.zst")!
        let config = ContainerSystemConfig(kernel: .init(url: url))
        #expect(
            InfoRoute.systemPropertyLabels(config: config).contains(
                "kernel.url=https://example.com/kernel.tar.zst"))
    }
}
