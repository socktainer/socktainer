import Foundation
import Logging
import Testing

@testable import socktainer

/// Docker filter semantics: multiple values for the same filter key OR
/// together (a network matches if it matches any value); different keys AND
/// together. The previous implementation honored only the first value of
/// name/id/driver/scope/type, silently dropping the rest — so
/// `docker network ls -f name=a -f name=b` returned only `a`.
@Suite("ClientNetworkService.applyFilters — OR semantics for repeated keys")
struct NetworkFilterOrSemanticsTests {

    private let logger = Logger(label: "test")

    @Test("Two name values return networks matching either name")
    func nameFilterOrsValues() {
        let networks = [Self.network(name: "alpha"), Self.network(name: "beta"), Self.network(name: "gamma")]
        let result = ClientNetworkService.applyFilters(networks, filters: #"{"name":["alpha","beta"]}"#, logger: logger)
        #expect(result.map(\.Name).sorted() == ["alpha", "beta"])
    }

    @Test("Two id values return networks matching either id")
    func idFilterOrsValues() {
        let networks = [Self.network(id: "id-one"), Self.network(id: "id-two"), Self.network(id: "id-three")]
        let result = ClientNetworkService.applyFilters(networks, filters: #"{"id":["id-one","id-two"]}"#, logger: logger)
        #expect(result.map(\.Id).sorted() == ["id-one", "id-two"])
    }

    @Test("Two driver values return networks matching either driver")
    func driverFilterOrsValues() {
        let networks = [Self.network(name: "n1", driver: "nat"), Self.network(name: "n2", driver: "bridge"), Self.network(name: "n3", driver: "host")]
        let result = ClientNetworkService.applyFilters(networks, filters: #"{"driver":["nat","bridge"]}"#, logger: logger)
        #expect(result.map(\.Name).sorted() == ["n1", "n2"])
    }

    @Test("type=custom plus type=builtin matches every network")
    func typeFilterOrsValues() {
        let networks = [Self.network(name: "custom-net", driver: "nat"), Self.network(name: "builtin-net", driver: "bridge")]
        let result = ClientNetworkService.applyFilters(networks, filters: #"{"type":["custom","builtin"]}"#, logger: logger)
        #expect(result.count == 2)
    }

    @Test("Different keys still AND together")
    func differentKeysStillAnd() {
        let networks = [
            Self.network(name: "alpha", driver: "nat"),
            Self.network(name: "alpha-bridge", driver: "bridge"),
            Self.network(name: "beta", driver: "nat"),
        ]
        let result = ClientNetworkService.applyFilters(networks, filters: #"{"name":["alpha"],"driver":["nat"]}"#, logger: logger)
        #expect(result.map(\.Name) == ["alpha"])
    }

    @Test("Single-value filters behave as before")
    func singleValueUnchanged() {
        let networks = [Self.network(name: "alpha"), Self.network(name: "beta")]
        let result = ClientNetworkService.applyFilters(networks, filters: #"{"name":["alpha"]}"#, logger: logger)
        #expect(result.map(\.Name) == ["alpha"])
    }

    @Test("Route-level parser accepts every moby network-ls filter key")
    func parserAcceptsAllMobyKeys() throws {
        // driver/scope/type were rejected with 400 before, so the OR fix for
        // those keys was unreachable through the HTTP routes.
        let filters = #"{"driver":["nat"],"scope":["local"],"type":["custom"],"name":["n"],"id":["i"],"label":["k=v"],"dangling":["true"]}"#
        let parsed = try DockerNetworkFilterUtility.parseNetworkFilters(filtersParam: filters, defaultDangling: false, logger: logger)
        #expect(Set(parsed.keys) == ["dangling", "driver", "id", "label", "name", "scope", "type"])
    }

    @Test("Route-level parser still rejects unknown filter keys")
    func parserRejectsUnknownKeys() {
        #expect(throws: (any Error).self) {
            try DockerNetworkFilterUtility.parseNetworkFilters(filtersParam: #"{"bogus":["x"]}"#, defaultDangling: false, logger: logger)
        }
    }

    // MARK: - Helpers

    private static func network(name: String = "net", id: String = "net-id", driver: String = "nat") -> RESTNetworkSummary {
        RESTNetworkSummary(
            Name: name, Id: id, Created: "", Scope: "local", Driver: driver,
            EnableIPv4: true, EnableIPv6: false, Internal: false, Attachable: false, Ingress: false,
            IPAM: NetworkIPAM(Driver: "", Config: []), Options: [:], Containers: nil,
            ConfigFrom: nil, Labels: [:], Subnet: nil, Gateway: nil)
    }
}
