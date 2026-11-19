import ContainerResource
import ContainerizationExtras
import Testing

@testable import socktainer

@Suite("NetworkNameNormalization")
struct NetworkNameNormalizationTests {

    @Test(
        "normalize lowercases the name and leaves everything else unchanged",
        arguments: [
            ("Foo", "foo"),
            ("aspire-session-network-ghfpwpdj-MyApp.Web", "aspire-session-network-ghfpwpdj-myapp.web"),
            ("Mixed-Case.Test", "mixed-case.test"),
            ("already-lower_1.2", "already-lower_1.2"),
            ("default", "default"),
        ])
    func normalize(input: String, expected: String) {
        #expect(NetworkNameNormalization.normalize(input) == expected)
    }

    @Test("a normalized name passes Apple Container's network name validation")
    func normalizedNameIsValidForAppleContainer() {
        let name = "aspire-session-network-ghfpwpdj-MyApp.Web"
        #expect(!NetworkResource.nameValid(name))
        #expect(NetworkResource.nameValid(NetworkNameNormalization.normalize(name)))
    }

    @Test("findNetwork resolves a mixed-case reference to the stored lowercase network")
    func findNetworkMixedCase() throws {
        let networks = [try makeSummary("default"), try makeSummary("mixed-case.test")]
        #expect(ClientNetworkService.findNetwork(in: networks, reference: "Mixed-Case.Test")?.Name == "mixed-case.test")
        #expect(ClientNetworkService.findNetwork(in: networks, reference: "mixed-case.test")?.Name == "mixed-case.test")
        #expect(ClientNetworkService.findNetwork(in: networks, reference: "Other") == nil)
    }
}

func makeSummary(_ name: String, mode: NetworkMode = .nat) throws -> RESTNetworkSummary {
    let configuration = try NetworkConfiguration(
        name: name,
        mode: mode,
        ipv4Subnet: nil,
        labels: ResourceLabels([:]),
        plugin: "container-network-vmnet"
    )
    let status = NetworkStatus(
        ipv4Subnet: try CIDRv4("192.168.100.0/24"),
        ipv4Gateway: try IPv4Address("192.168.100.1"),
        ipv6Subnet: nil
    )
    return RESTNetworkSummary(networkResource: NetworkResource(configuration: configuration, status: status))
}
