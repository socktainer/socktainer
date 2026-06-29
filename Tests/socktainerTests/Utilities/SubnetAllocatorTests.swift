import Testing

@testable import socktainer

@Suite("SubnetAllocator")
struct SubnetAllocatorTests {

    @Test("Picks the highest subnet in range on an empty network list")
    func emptyPicksRangeTop() {
        #expect(SubnetAllocator.nextFreeSubnet(usedSubnets: []) == "192.168.254.0/24")
    }

    @Test("Skips subnets already in use, scanning downward")
    func skipsUsedScanningDown() {
        let used = ["192.168.254.0/24", "192.168.253.0/24"]
        #expect(SubnetAllocator.nextFreeSubnet(usedSubnets: used) == "192.168.252.0/24")
    }

    @Test("Subnets outside 192.168 never block allocation")
    func ignoresOutOf192168() {
        let used = ["192.168.64.0/24", "192.168.67.0/24", "10.0.0.0/24"]
        #expect(SubnetAllocator.nextFreeSubnet(usedSubnets: used) == "192.168.254.0/24")
    }

    @Test("Accepts bare gateway addresses, not just CIDRs")
    func acceptsBareAddresses() {
        #expect(SubnetAllocator.nextFreeSubnet(usedSubnets: ["192.168.254.1"]) == "192.168.253.0/24")
    }

    @Test("Excluded octets are skipped after a subnet-collision race")
    func excludedSkipped() {
        let result = SubnetAllocator.nextFreeSubnet(usedSubnets: [], excluded: [254, 253])
        #expect(result == "192.168.252.0/24")
    }

    @Test("Returns nil when the whole range is exhausted")
    func exhaustedReturnsNil() {
        let used = (16...254).map { "192.168.\($0).0/24" }
        #expect(SubnetAllocator.nextFreeSubnet(usedSubnets: used) == nil)
    }

    @Test("Stays clear of common home-LAN subnets below the floor")
    func staysAboveFloor() {
        let usedAboveFloor = (16...254).map { "192.168.\($0).0/24" }
        #expect(SubnetAllocator.nextFreeSubnet(usedSubnets: usedAboveFloor) == nil, "must not fall into 192.168.0/1.x")
    }

    @Test("thirdOctet parses 192.168 addresses and rejects others")
    func thirdOctetParsing() {
        #expect(SubnetAllocator.thirdOctet(of: "192.168.207.0/24") == 207)
        #expect(SubnetAllocator.thirdOctet(of: "192.168.207.1") == 207)
        #expect(SubnetAllocator.thirdOctet(of: "10.1.2.3") == nil)
        #expect(SubnetAllocator.thirdOctet(of: "garbage") == nil)
    }
}
