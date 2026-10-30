import Foundation
import Testing

@testable import socktainer

@Suite("DNSUpstream")
struct DNSUpstreamTests {

    @Test("Host only uses default port 53")
    func hostOnly() throws {
        #expect(try DNSUpstream.parse("127.0.0.1") == DNSUpstream(host: "127.0.0.1", port: 53))
    }

    @Test("Host and port")
    func hostAndPort() throws {
        #expect(try DNSUpstream.parse("10.0.0.2:5353") == DNSUpstream(host: "10.0.0.2", port: 5353))
        #expect(try DNSUpstream.parse("1.1.1.1:1").port == 1)
        #expect(try DNSUpstream.parse("1.1.1.1:65535").port == 65535)
    }

    @Test("Surrounding whitespace is trimmed")
    func whitespace() throws {
        #expect(try DNSUpstream.parse("  127.0.0.1:5353\n") == DNSUpstream(host: "127.0.0.1", port: 5353))
    }

    @Test("Empty or blank value is rejected")
    func empty() {
        #expect(throws: DNSUpstream.ParseError.empty) { try DNSUpstream.parse("") }
        #expect(throws: DNSUpstream.ParseError.empty) { try DNSUpstream.parse("   ") }
    }

    @Test("Invalid IPv4 host is rejected")
    func invalidHost() {
        #expect(throws: DNSUpstream.ParseError.invalidHost("256.1.1.1")) { try DNSUpstream.parse("256.1.1.1") }
        #expect(throws: DNSUpstream.ParseError.invalidHost("1.2.3")) { try DNSUpstream.parse("1.2.3:53") }
        #expect(throws: DNSUpstream.ParseError.invalidHost("")) { try DNSUpstream.parse(":53") }
    }

    @Test("Hostname is rejected")
    func hostname() {
        #expect(throws: DNSUpstream.ParseError.invalidHost("dns.example.com")) { try DNSUpstream.parse("dns.example.com") }
        #expect(throws: DNSUpstream.ParseError.invalidHost("localhost")) { try DNSUpstream.parse("localhost:53") }
    }

    @Test("IPv6 is rejected")
    func ipv6() {
        #expect(throws: DNSUpstream.ParseError.invalidHost("::1")) { try DNSUpstream.parse("::1") }
        #expect(throws: DNSUpstream.ParseError.invalidHost("[::1]:53")) { try DNSUpstream.parse("[::1]:53") }
        #expect(throws: DNSUpstream.ParseError.invalidHost("2001:4860:4860::8888")) { try DNSUpstream.parse("2001:4860:4860::8888") }
    }

    @Test("Out-of-range and non-numeric ports are rejected")
    func invalidPort() {
        #expect(throws: DNSUpstream.ParseError.invalidPort("0")) { try DNSUpstream.parse("1.1.1.1:0") }
        #expect(throws: DNSUpstream.ParseError.invalidPort("65536")) { try DNSUpstream.parse("1.1.1.1:65536") }
        #expect(throws: DNSUpstream.ParseError.invalidPort("abc")) { try DNSUpstream.parse("1.1.1.1:abc") }
        #expect(throws: DNSUpstream.ParseError.invalidPort("")) { try DNSUpstream.parse("1.1.1.1:") }
        #expect(throws: DNSUpstream.ParseError.invalidPort("-1")) { try DNSUpstream.parse("1.1.1.1:-1") }
    }

    @Test("Leading zeros in the port are accepted")
    func leadingZeroPort() throws {
        #expect(try DNSUpstream.parse("1.2.3.4:053") == DNSUpstream(host: "1.2.3.4", port: 53))
    }

    @Test("Host is normalized to canonical dotted-quad")
    func canonicalHost() throws {
        #expect(try DNSUpstream.parse("01.2.3.4") == DNSUpstream(host: "1.2.3.4", port: 53))
        #expect(try DNSUpstream.parse("0127.0.0.1:2054").pointsAtSelf(dnsPort: 2054))
    }

    @Test("Trailing dot is rejected")
    func trailingDot() {
        #expect(throws: DNSUpstream.ParseError.self) { try DNSUpstream.parse("1.1.1.1.") }
    }

    @Test("Unspecified and broadcast addresses are rejected")
    func unusableAddresses() {
        #expect(throws: DNSUpstream.ParseError.unusableAddress("0.0.0.0")) { try DNSUpstream.parse("0.0.0.0") }
        #expect(throws: DNSUpstream.ParseError.unusableAddress("0.0.0.0")) { try DNSUpstream.parse("0.0.0.0:2054") }
        #expect(throws: DNSUpstream.ParseError.unusableAddress("255.255.255.255")) { try DNSUpstream.parse("255.255.255.255") }
    }

    // MARK: - Self-reference

    @Test("Loopback upstream on the server's own port points at self")
    func pointsAtSelfTrue() {
        #expect(DNSUpstream(host: "127.0.0.1", port: 2054).pointsAtSelf(dnsPort: 2054))
        #expect(DNSUpstream(host: "127.1.2.3", port: 2054).pointsAtSelf(dnsPort: 2054))
    }

    @Test("Other ports or non-loopback hosts do not point at self")
    func pointsAtSelfFalse() {
        #expect(!DNSUpstream(host: "127.0.0.1", port: 53).pointsAtSelf(dnsPort: 2054))
        #expect(!DNSUpstream(host: "10.0.0.1", port: 2054).pointsAtSelf(dnsPort: 2054))
    }

    // MARK: - Precedence

    @Test("Neither set resolves to auto-detection")
    func neitherSet() {
        let result = DNSUpstream.resolve(cliValue: nil, environment: [:])
        #expect(result == DNSUpstream.Resolution(upstream: nil, warning: nil))
    }

    @Test("Environment variable is used when no CLI value")
    func envOnly() {
        let result = DNSUpstream.resolve(cliValue: nil, environment: ["SOCKTAINER_DNS_UPSTREAM": "127.0.0.1:5353"])
        #expect(result.upstream == DNSUpstream(host: "127.0.0.1", port: 5353))
        #expect(result.warning == nil)
    }

    @Test("CLI value wins over environment variable")
    func cliWins() {
        let result = DNSUpstream.resolve(cliValue: "10.1.1.1", environment: ["SOCKTAINER_DNS_UPSTREAM": "127.0.0.1:5353"])
        #expect(result.upstream == DNSUpstream(host: "10.1.1.1", port: 53))
        #expect(result.warning == nil)
    }

    @Test("Invalid CLI value is ignored with a warning, then environment is used")
    func invalidCLI() {
        let result = DNSUpstream.resolve(cliValue: "bogus", environment: ["SOCKTAINER_DNS_UPSTREAM": "10.1.1.1"])
        #expect(result.upstream == DNSUpstream(host: "10.1.1.1", port: 53))
        #expect(result.warning?.contains("--dns-upstream") == true)

        let none = DNSUpstream.resolve(cliValue: "bogus", environment: [:])
        #expect(none.upstream == nil)
        #expect(none.warning?.contains("--dns-upstream") == true)
    }

    @Test("Invalid environment variable warns and falls back to auto-detection")
    func invalidEnv() {
        let result = DNSUpstream.resolve(cliValue: nil, environment: ["SOCKTAINER_DNS_UPSTREAM": "dns.example.com"])
        #expect(result.upstream == nil)
        #expect(result.warning?.contains("SOCKTAINER_DNS_UPSTREAM") == true)
    }

    @Test("Blank environment variable is treated as unset")
    func blankEnv() {
        let result = DNSUpstream.resolve(cliValue: nil, environment: ["SOCKTAINER_DNS_UPSTREAM": "  "])
        #expect(result == DNSUpstream.Resolution(upstream: nil, warning: nil))
    }
}
