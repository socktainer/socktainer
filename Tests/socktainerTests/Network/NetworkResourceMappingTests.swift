import ContainerResource
import ContainerizationExtras
import Foundation
import Testing

@testable import socktainer

// MARK: - Helpers

private func makeNetworkResource(
    name: String = "testnet",
    mode: NetworkMode = .nat,
    configSubnet: String? = nil,
    statusSubnet: String = "192.168.100.0/24",
    gateway: String = "192.168.100.1",
    labels: [String: String] = [:]
) throws -> NetworkResource {
    let configuration = try NetworkConfiguration(
        name: name,
        mode: mode,
        ipv4Subnet: configSubnet.map { try CIDRv4($0) },
        labels: ResourceLabels(labels),
        plugin: "container-network-vmnet"
    )
    let status = NetworkStatus(
        ipv4Subnet: try CIDRv4(statusSubnet),
        ipv4Gateway: try IPv4Address(gateway),
        ipv6Subnet: nil
    )
    return NetworkResource(configuration: configuration, status: status)
}

/// NetworkConfiguration.init always sets creationDate = Date(), so we go through
/// Codable with secondsSince1970 to inject a controlled timestamp in tests.
private func makeNetworkResourceWithDate(
    name: String = "testnet",
    labels: [String: String] = [:],
    creationDate: Date
) throws -> NetworkResource {
    let labelsJSON =
        (try? String(data: JSONSerialization.data(withJSONObject: labels), encoding: .utf8)) ?? "{}"
    let configJSON = """
        {"name":"\(name)","mode":"nat","creationDate":\(creationDate.timeIntervalSince1970),"labels":\(labelsJSON),"plugin":"container-network-vmnet","options":{}}
        """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let configuration = try decoder.decode(NetworkConfiguration.self, from: configJSON)
    let status = NetworkStatus(
        ipv4Subnet: try CIDRv4("192.168.100.0/24"),
        ipv4Gateway: try IPv4Address("192.168.100.1"),
        ipv6Subnet: nil
    )
    return NetworkResource(configuration: configuration, status: status)
}

// MARK: - RESTNetworkSummary mapping

@Suite("NetworkResource → RESTNetworkSummary mapping")
struct NetworkResourceMappingTests {

    @Test("Name and Id both come from configuration.name")
    func nameAndIdFromConfigurationName() throws {
        let resource = try makeNetworkResource(name: "mynetwork")
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.Name == "mynetwork")
        #expect(summary.Id == "mynetwork")
    }

    @Test("Subnet comes from configuration.ipv4Subnet when present")
    func subnetFromConfiguration() throws {
        let resource = try makeNetworkResource(configSubnet: "10.0.0.0/8", statusSubnet: "192.168.0.0/16")
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.Subnet == "10.0.0.0/8")
    }

    @Test("Subnet falls back to status.ipv4Subnet when configuration.ipv4Subnet is nil")
    func subnetFallsBackToStatus() throws {
        let resource = try makeNetworkResource(configSubnet: nil, statusSubnet: "172.20.0.0/16")
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.Subnet == "172.20.0.0/16")
    }

    @Test("Gateway always comes from status.ipv4Gateway")
    func gatewayFromStatus() throws {
        let resource = try makeNetworkResource(gateway: "10.0.0.1")
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.Gateway == "10.0.0.1")
    }

    @Test("Labels are mapped from configuration.labels")
    func labelsFromConfiguration() throws {
        let resource = try makeNetworkResource(labels: ["env": "test", "team": "platform"])
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.Labels["env"] == "test")
        #expect(summary.Labels["team"] == "platform")
    }

    @Test("Static fields have expected values")
    func staticFields() throws {
        let resource = try makeNetworkResource()
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.Scope == "local")
        #expect(summary.EnableIPv4 == true)
        #expect(summary.EnableIPv6 == false)
        #expect(summary.Internal == false)
        #expect(summary.Attachable == false)
        #expect(summary.Ingress == false)
    }

    @Test("Containers is nil by default (populated separately in list())")
    func containersNilByDefault() throws {
        let resource = try makeNetworkResource()
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.Containers == nil)
    }

    @Test("IPAM.Config carries the subnet and gateway (Docker-standard location)")
    func ipamConfigCarriesSubnetAndGateway() throws {
        let resource = try makeNetworkResource(configSubnet: "10.0.0.0/8", gateway: "10.0.0.1")
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.IPAM.Driver == "default")
        #expect(summary.IPAM.Config.count == 1)
        #expect(summary.IPAM.Config.first?.Subnet == "10.0.0.0/8")
        #expect(summary.IPAM.Config.first?.Gateway == "10.0.0.1")
    }

    @Test("IPAM.Config subnet falls back to status subnet when configuration.ipv4Subnet is nil")
    func ipamConfigFallsBackToStatusSubnet() throws {
        let resource = try makeNetworkResource(configSubnet: nil, statusSubnet: "172.20.0.0/16")
        let summary = RESTNetworkSummary(networkResource: resource)
        #expect(summary.IPAM.Config.first?.Subnet == "172.20.0.0/16")
    }
}

// MARK: - AppleContainerTimestampResolver.networkCreationDate

@Suite("AppleContainerTimestampResolver.networkCreationDate")
struct NetworkCreationDateTests {

    @Test("Returns configuration.creationDate when it is after the epoch")
    func returnsConfigurationDateWhenValid() throws {
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let resource = try makeNetworkResourceWithDate(creationDate: expectedDate)
        let result = AppleContainerTimestampResolver.networkCreationDate(resource)
        #expect(result == expectedDate)
    }

    @Test("Falls back to legacy label when creationDate is epoch")
    func fallsBackToLegacyLabel() throws {
        let labelTimestamp = 1_600_000_000.0
        let resource = try makeNetworkResourceWithDate(
            labels: [AppleContainerTimestampResolver.legacyCreationTimestampLabel: "\(labelTimestamp)"],
            creationDate: Date(timeIntervalSince1970: 0)
        )
        let result = AppleContainerTimestampResolver.networkCreationDate(resource)
        #expect(result == Date(timeIntervalSince1970: labelTimestamp))
    }

    @Test("Returns nil when creationDate is epoch and no legacy label is present")
    func returnsNilWhenNoDateAndNoLabel() throws {
        let resource = try makeNetworkResourceWithDate(creationDate: Date(timeIntervalSince1970: 0))
        let result = AppleContainerTimestampResolver.networkCreationDate(resource)
        #expect(result == nil)
    }

    @Test("Does not fall back to label when creationDate is valid")
    func doesNotUseLabelWhenDateIsValid() throws {
        let configDate = Date(timeIntervalSince1970: 1_700_000_000)
        let resource = try makeNetworkResourceWithDate(
            labels: [AppleContainerTimestampResolver.legacyCreationTimestampLabel: "1600000000"],
            creationDate: configDate
        )
        let result = AppleContainerTimestampResolver.networkCreationDate(resource)
        #expect(result == configDate)
    }
}
