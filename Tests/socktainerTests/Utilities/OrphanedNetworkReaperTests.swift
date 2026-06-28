import Testing

@testable import socktainer

@Suite("OrphanedNetworkReaper — startup network reaping")
struct OrphanedNetworkReaperTests {

    private func network(name: String, id: String, containers: [String: NetworkContainer]?) -> RESTNetworkSummary {
        RESTNetworkSummary(
            Name: name, Id: id, Created: "", Scope: "local", Driver: "nat",
            EnableIPv4: true, EnableIPv6: false, Internal: false, Attachable: false, Ingress: false,
            IPAM: NetworkIPAM(Driver: "", Config: []), Options: [:], Containers: containers,
            ConfigFrom: nil, Labels: [:], Subnet: nil, Gateway: nil)
    }

    private let member = NetworkContainer(
        Name: "app", EndpointID: nil, MacAddress: nil, IPv4Address: "192.168.66.4", IPv6Address: nil)

    @Test("empty non-default network is reaped")
    func emptyNetworkReaped() {
        let nets = [network(name: "supabase_network_socktainer", id: "net-1", containers: [:])]
        #expect(OrphanedNetworkReaper.orphanedNetworkIDs(from: nets) == ["net-1"])
    }

    @Test("nil-containers network is treated as empty and reaped")
    func nilContainersReaped() {
        let nets = [network(name: "leftover", id: "net-2", containers: nil)]
        #expect(OrphanedNetworkReaper.orphanedNetworkIDs(from: nets) == ["net-2"])
    }

    @Test("network with attached containers is kept")
    func populatedNetworkKept() {
        let nets = [network(name: "in-use", id: "net-3", containers: ["c1": member])]
        #expect(OrphanedNetworkReaper.orphanedNetworkIDs(from: nets).isEmpty)
    }

    @Test("the built-in default network is never reaped, even when empty")
    func defaultNetworkProtected() {
        let nets = [network(name: "default", id: "default", containers: [:])]
        #expect(OrphanedNetworkReaper.orphanedNetworkIDs(from: nets).isEmpty)
    }

    @Test("mixed set: only empty non-default networks are returned")
    func mixedSet() {
        let nets = [
            network(name: "default", id: "default", containers: [:]),
            network(name: "orphan-a", id: "a", containers: [:]),
            network(name: "busy", id: "b", containers: ["c1": member]),
            network(name: "orphan-c", id: "c", containers: nil),
        ]
        #expect(Set(OrphanedNetworkReaper.orphanedNetworkIDs(from: nets)) == ["a", "c"])
    }
}
