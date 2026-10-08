import Testing

@testable import socktainer

@Suite("ExtraHostsFile")
struct ExtraHostsFileTests {

    @Test("Parses legacy host:ip, host=ip, and IPv6 forms")
    func parsesEntries() {
        #expect(ExtraHostsFile.parse("foo:1.2.3.4")! == ("foo", "1.2.3.4"))
        #expect(ExtraHostsFile.parse("foo=1.2.3.4")! == ("foo", "1.2.3.4"))
        #expect(ExtraHostsFile.parse("foo:::1")! == ("foo", "::1"))
        #expect(ExtraHostsFile.parse("foo=[::1]")! == ("foo", "::1"))
        #expect(ExtraHostsFile.parse("badentry") == nil)
        #expect(ExtraHostsFile.parse("foo:") == nil)
    }

    @Test("Renders extra hosts and the container's own address")
    func rendersExtraHostsAndOwnAddress() {
        let content = ExtraHostsFile.render(
            extraHosts: ["foo.example:10.1.2.3", "gw:host-gateway"], ip: "192.168.64.5", hostname: "web",
            gateway: "192.168.64.1")
        let lines = content.split(separator: "\n").map(String.init)
        #expect(lines.first == "127.0.0.1\tlocalhost")
        #expect(lines.contains("10.1.2.3\tfoo.example"))
        #expect(lines.contains("192.168.64.1\tgw"))
        #expect(lines.last == "192.168.64.5\tweb")
    }

    @Test("Before bootstrap: no own-address line and host-gateway is skipped")
    func rendersWithoutNetwork() {
        let content = ExtraHostsFile.render(
            extraHosts: ["foo:10.1.2.3", "gw:host-gateway"], ip: nil, hostname: "web", gateway: nil)
        #expect(content.contains("10.1.2.3\tfoo\n"))
        #expect(!content.contains("\tgw"))
        #expect(!content.contains("\tweb"))
    }
}
