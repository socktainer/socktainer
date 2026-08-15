import Testing

@testable import GlassDock

@Suite("IP address utility")
struct IPAddressUtilityTests {
    @Test("removes a CIDR prefix length")
    func removesPrefixLength() {
        #expect(stripSubnetFromIP("192.168.1.2/24") == "192.168.1.2")
        #expect(stripSubnetFromIP("2001:db8::1/64") == "2001:db8::1")
        #expect(stripSubnetFromIP(nil) == nil)
    }
}
