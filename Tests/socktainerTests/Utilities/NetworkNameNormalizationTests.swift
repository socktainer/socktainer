import ContainerResource
import ContainerizationExtras
import Foundation
import Logging
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

    // MARK: - Names still invalid after lowercasing

    static let invalidNames = [
        String(repeating: "a", count: 64),
        "aspire-session-network-ghfpwpdj-Contoso.Enterprise.Inventory.Management.Web.Frontend",
        String(repeating: "x", count: 200),
        "my network",
        "team/app:net",
        "réseau-ünïcode",
        "foo_",
        "_foo",
        ".foo.",
        "-foo-",
        "___",
        "",
    ]

    @Test("normalize always yields a name Apple Container accepts", arguments: invalidNames)
    func normalizedInvalidNameIsValid(input: String) {
        let normalized = NetworkNameNormalization.normalize(input)
        #expect(NetworkResource.nameValid(normalized), "\(normalized)")
        #expect(normalized.count <= 63)
    }

    @Test("normalize is deterministic and idempotent", arguments: invalidNames)
    func normalizeIsDeterministicAndIdempotent(input: String) {
        let normalized = NetworkNameNormalization.normalize(input)
        #expect(NetworkNameNormalization.normalize(input) == normalized)
        #expect(NetworkNameNormalization.normalize(normalized) == normalized)
    }

    @Test("names that differ only in replaced or trimmed characters do not collide")
    func replacedNamesDoNotCollide() {
        let normalize = NetworkNameNormalization.normalize
        #expect(normalize("foo_") != normalize("foo"))
        #expect(normalize("a b") != normalize("a-b"))
        let shared = String(repeating: "s", count: 60)
        #expect(normalize(shared + "-one") != normalize(shared + "-two"))
    }

    @Test("case variants of a long name map to the same stored name")
    func longNameCaseVariantsMatch() {
        let long = "aspire-session-network-ghfpwpdj-Contoso.Enterprise.Inventory.Management.Web.Frontend"
        #expect(NetworkNameNormalization.normalize(long) == NetworkNameNormalization.normalize(long.uppercased()))
    }

    @Test("findNetwork resolves an over-long original name to its shortened stored network")
    func findNetworkLongName() throws {
        let long = "aspire-session-network-ghfpwpdj-Contoso.Enterprise.Inventory.Management.Web.Frontend"
        let stored = NetworkNameNormalization.normalize(long)
        let networks = [try makeSummary("default"), try makeSummary(stored)]
        #expect(ClientNetworkService.findNetwork(in: networks, reference: long)?.Id == stored)
    }

    // MARK: - Original name preserved in a label

    @Test("a network with the original-name label reports it as Name and hides the label")
    func summaryReportsOriginalName() throws {
        let summary = try makeSummary(
            "mixed-case.test",
            labels: [NetworkNameNormalization.originalNameLabel: "Mixed-Case.Test", "app": "web"])
        #expect(summary.Name == "Mixed-Case.Test")
        #expect(summary.Id == "mixed-case.test")
        #expect(summary.Labels == ["app": "web"])
    }

    @Test("a network without the label reports its stored name")
    func summaryWithoutLabel() throws {
        let summary = try makeSummary("plain")
        #expect(summary.Name == "plain")
        #expect(summary.Id == "plain")
    }

    @Test("findNetwork resolves the original name, the stored id and case variants")
    func findNetworkByOriginalName() throws {
        let networks = [
            try makeSummary("mixed-case.test", labels: [NetworkNameNormalization.originalNameLabel: "Mixed-Case.Test"])
        ]
        for reference in ["Mixed-Case.Test", "mixed-case.test", "MIXED-CASE.TEST"] {
            #expect(ClientNetworkService.findNetwork(in: networks, reference: reference)?.Id == "mixed-case.test")
        }
    }

    @Test("the normalized lookup pass matches the stored id, not the display name")
    func normalizedPassUsesIdOnly() throws {
        // Display name "zzz" normalizes to itself; a reference "ZZZ" must not match via Name.
        let networks = [try makeSummary("stored-id", labels: [NetworkNameNormalization.originalNameLabel: "zzz"])]
        #expect(ClientNetworkService.findNetwork(in: networks, reference: "ZZZ") == nil)
    }

    @Test("the name filter matches the original and the stored name; the internal label is not filterable")
    func nameFilterAndHiddenLabel() throws {
        let networks = [
            try makeSummary(
                NetworkNameNormalization.normalize("Contoso.Enterprise.Inventory.Management.Web.Frontend.Service.Network"),
                labels: [NetworkNameNormalization.originalNameLabel: "Contoso.Enterprise.Inventory.Management.Web.Frontend.Service.Network"]),
            try makeSummary("other"),
        ]
        let logger = Logger(label: "test")
        let byOriginal = ClientNetworkService.applyFilters(networks, filters: #"{"name":["Frontend.Service"]}"#, logger: logger)
        #expect(byOriginal.map(\.Name) == ["Contoso.Enterprise.Inventory.Management.Web.Frontend.Service.Network"])
        let byStored = ClientNetworkService.applyFilters(networks, filters: #"{"name":["other"]}"#, logger: logger)
        #expect(byStored.map(\.Id) == ["other"])
        let byLabel = ClientNetworkService.applyFilters(
            networks, filters: #"{"label":["\#(NetworkNameNormalization.originalNameLabel)"]}"#, logger: logger)
        #expect(byLabel.isEmpty)
    }

    // MARK: - Container display names

    @Test("the container label maps stored names to the network's recorded original name")
    func containerLabelUsesNetworkOriginalName() async throws {
        let value = await NetworkNameNormalization.containerNetworkNamesLabelValue(
            requestedNames: ["mixed-case.test"],
            storedNames: ["mixed-case.test"],
            originalName: { $0 == "mixed-case.test" ? "Mixed-Case.Test" : nil }
        )
        let map = try JSONDecoder().decode([String: String].self, from: Data(try #require(value).utf8))
        #expect(map == ["mixed-case.test": "Mixed-Case.Test"])
    }

    @Test("the container label falls back to the requested name when the network has no label")
    func containerLabelFallsBackToRequestedName() async throws {
        let value = await NetworkNameNormalization.containerNetworkNamesLabelValue(
            requestedNames: ["Legacy-Net"],
            storedNames: ["legacy-net"],
            originalName: { _ in nil }
        )
        let map = try JSONDecoder().decode([String: String].self, from: Data(try #require(value).utf8))
        #expect(map == ["legacy-net": "Legacy-Net"])
    }

    @Test("no container label when every display name equals the stored name")
    func noContainerLabelWhenUnchanged() async {
        let value = await NetworkNameNormalization.containerNetworkNamesLabelValue(
            requestedNames: ["plain", "bridge"],
            storedNames: ["plain", "default"],
            originalName: { _ in nil }
        )
        #expect(value == nil)
    }

    @Test("displayKeyed and displayName use the container label, falling back to the stored name")
    func displayKeyedRemaps() {
        let labels = [NetworkNameNormalization.containerNetworkNamesLabel: #"{"mixed-case.test":"Mixed-Case.Test"}"#]
        let remapped = NetworkNameNormalization.displayKeyed(["mixed-case.test": 1, "default": 2], containerLabels: labels)
        #expect(remapped == ["Mixed-Case.Test": 1, "default": 2])
        #expect(NetworkNameNormalization.displayName(storedName: "mixed-case.test", containerLabels: labels) == "Mixed-Case.Test")
        #expect(NetworkNameNormalization.displayKeyed(["a": 1], containerLabels: [:]) == ["a": 1])
    }
}

func makeSummary(_ name: String, mode: NetworkMode = .nat, labels: [String: String] = [:]) throws -> RESTNetworkSummary {
    let configuration = try NetworkConfiguration(
        name: name,
        mode: mode,
        ipv4Subnet: nil,
        labels: ResourceLabels(labels),
        plugin: "container-network-vmnet"
    )
    let status = NetworkStatus(
        ipv4Subnet: try CIDRv4("192.168.100.0/24"),
        ipv4Gateway: try IPv4Address("192.168.100.1"),
        ipv6Subnet: nil
    )
    return RESTNetworkSummary(networkResource: NetworkResource(configuration: configuration, status: status))
}
