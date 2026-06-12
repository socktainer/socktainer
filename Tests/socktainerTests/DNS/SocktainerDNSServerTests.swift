import Darwin
import Testing

@testable import socktainer

@Suite("SocktainerDNSServer")
struct SocktainerDNSServerTests {

    // MARK: - Registration

    @Test("Register and retrieve a hostname")
    func registerAndRetrieve() {
        let server = SocktainerDNSServer()
        server.register(hostname: "postgres", ip: "192.168.1.10")
        let entries = server.listEntries()
        #expect(entries["postgres"] == "192.168.1.10")
    }

    @Test("Unregister removes the hostname")
    func unregisterRemoves() {
        let server = SocktainerDNSServer()
        server.register(hostname: "redis", ip: "192.168.1.20")
        server.unregister(hostname: "redis")
        #expect(server.listEntries()["redis"] == nil)
    }

    @Test("Unregistering unknown hostname is a no-op")
    func unregisterUnknownIsNoOp() {
        let server = SocktainerDNSServer()
        server.unregister(hostname: "nonexistent")  // must not crash
        #expect(server.listEntries().isEmpty)
    }

    // MARK: - Normalization

    @Test("Hostname lookup is case-insensitive")
    func caseInsensitive() {
        let server = SocktainerDNSServer()
        server.register(hostname: "MyService", ip: "10.0.0.1")
        let entries = server.listEntries()
        #expect(entries["myservice"] == "10.0.0.1")
    }

    @Test("Trailing dot is stripped on normalize")
    func trailingDotStripped() {
        #expect(SocktainerDNSServer.normalize("postgres.") == "postgres")
        #expect(SocktainerDNSServer.normalize("db..") == "db")
        #expect(SocktainerDNSServer.normalize("svc") == "svc")
    }

    // MARK: - IP parsing

    @Test("CIDR suffix is stripped before parsing IP")
    func cidrSuffixStripped() {
        let server = SocktainerDNSServer()
        // Apple Container returns IPs as "192.168.1.5/24" — the slash must be stripped
        server.register(hostname: "db", ip: "192.168.1.5/24")
        #expect(server.listEntries()["db"] == "192.168.1.5")
    }

    @Test("Invalid IP is ignored gracefully")
    func invalidIPIgnored() {
        let server = SocktainerDNSServer()
        server.register(hostname: "broken", ip: "not-an-ip")
        #expect(server.listEntries()["broken"] == nil)
    }

    // MARK: - Port selection

    @Test("start() returns the resolved port")
    func startReturnsPort() {
        let server = SocktainerDNSServer()
        // Pick an unlikely port range for testing; just verify start() returns a non-nil Int
        let port = server.start(preferredPort: 19900, maxAttempts: 5)
        #expect(port != nil)
        if let p = port {
            #expect(p >= 19900 && p < 19905)
        }
    }

    @Test("start() falls back when preferred port is taken")
    func startFallsBack() throws {
        // Bind a socket on 19800 to simulate the port being taken
        let blocker = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard blocker >= 0 else { return }
        defer { Darwin.close(blocker) }
        var yes: Int32 = 1
        setsockopt(blocker, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(19800).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else { return }  // skip if bind fails (e.g. CI port conflict)

        let server = SocktainerDNSServer()
        let port = server.start(preferredPort: 19800, maxAttempts: 5)
        #expect(port != nil)
        #expect(port != 19800)  // must have fallen back
        #expect(port! > 19800 && port! < 19805)
    }

    // MARK: - Multiple entries

    @Test("Multiple hostnames can coexist independently")
    func multipleEntries() {
        let server = SocktainerDNSServer()
        server.register(hostname: "postgres", ip: "10.0.0.1")
        server.register(hostname: "redis", ip: "10.0.0.2")
        server.register(hostname: "api", ip: "10.0.0.3")
        let entries = server.listEntries()
        #expect(entries.count == 3)
        #expect(entries["postgres"] == "10.0.0.1")
        #expect(entries["redis"] == "10.0.0.2")
        #expect(entries["api"] == "10.0.0.3")
    }

    @Test("Re-registering a hostname overwrites the IP")
    func reregistrationOverwrites() {
        let server = SocktainerDNSServer()
        server.register(hostname: "db", ip: "10.0.0.1")
        server.register(hostname: "db", ip: "10.0.0.99")
        #expect(server.listEntries()["db"] == "10.0.0.99")
    }
}
