import Darwin
import Foundation
import Testing

@testable import socktainer

@Suite("SocktainerDNSServer system resolver failover")
struct SystemResolverFailoverTests {
    /// Loopback UDP stub that answers every query with `rcode`. Returns its port.
    private func startStub(rcode: UInt8) throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(fd >= 0)
        var tv = timeval(tv_sec: 12, tv_usec: 0)  // lets the stub thread exit after the test
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        try #require(bound)
        let thread = Thread {
            var buf = [UInt8](repeating: 0, count: 512)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            while true {
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
                }
                guard n >= 12 else { return }
                buf[2] |= 0x80
                buf[3] = (buf[3] & 0xF0) | rcode
                _ = withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buf, n, 0, $0, fromLen) }
                }
            }
        }
        thread.start()
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }

    /// Retries: the server binds on a background thread, so the first datagram can be lost.
    private func query(name: String, port: Int) -> UInt8? {
        for _ in 0..<3 {
            if let rcode = queryOnce(name: name, port: port) { return rcode }
        }
        return nil
    }

    private func queryOnce(name: String, port: Int) -> UInt8? {
        var packet: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet += Array(label.utf8)
        }
        packet += [0, 0, 1, 0, 1]
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = packet.withUnsafeBytes { p in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, p.baseAddress!, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        return n >= 4 ? buf[3] & 0x0F : nil
    }

    @Test("A refusing or unreachable resolver falls through to the next one")
    func failover() throws {
        let refusing = try startStub(rcode: 5)
        let good = try startStub(rcode: 3)  // NXDOMAIN counts as a real answer
        defer {
            Darwin.close(refusing.fd)
            Darwin.close(good.fd)
        }
        let server = SocktainerDNSServer()
        server.systemResolvers = [
            DNSUpstream(host: "127.0.0.1", port: 1),  // nothing listens: times out or is refused
            DNSUpstream(host: "127.0.0.1", port: refusing.port),
            DNSUpstream(host: "127.0.0.1", port: good.port),
        ]
        guard let port = server.start(preferredPort: 19830, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        #expect(query(name: "registry.example.com", port: port) == 3)
    }

    @Test("The resolver list can be replaced while the server runs")
    func liveUpdate() throws {
        let first = try startStub(rcode: 5)
        let second = try startStub(rcode: 3)
        defer {
            Darwin.close(first.fd)
            Darwin.close(second.fd)
        }
        let server = SocktainerDNSServer()
        server.systemResolvers = [DNSUpstream(host: "127.0.0.1", port: first.port)]
        guard let port = server.start(preferredPort: 19840, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        #expect(query(name: "registry.example.com", port: port) == 5)
        server.systemResolvers = [DNSUpstream(host: "127.0.0.1", port: second.port)]
        #expect(query(name: "registry.example.com", port: port) == 3)
    }

    @Test("An empty resolver list uses the single upstream")
    func emptyListUsesUpstream() throws {
        let stub = try startStub(rcode: 3)
        defer { Darwin.close(stub.fd) }
        let server = SocktainerDNSServer()
        server.setUpstream(host: "127.0.0.1", port: stub.port)
        guard let port = server.start(preferredPort: 19850, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        #expect(query(name: "registry.example.com", port: port) == 3)
    }

    @Test("When every resolver fails the first failure answer is returned")
    func allFail() throws {
        let first = try startStub(rcode: 5)
        let second = try startStub(rcode: 2)
        defer {
            Darwin.close(first.fd)
            Darwin.close(second.fd)
        }
        let server = SocktainerDNSServer()
        server.systemResolvers = [
            DNSUpstream(host: "127.0.0.1", port: first.port), DNSUpstream(host: "127.0.0.1", port: second.port),
        ]
        guard let port = server.start(preferredPort: 19860, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        #expect(query(name: "registry.example.com", port: port) == 5)
    }

    @Test("Only SERVFAIL and REFUSED move on to the next resolver")
    func tryNextRule() {
        func response(rcode: UInt8) -> [UInt8] { [0x12, 0x34, 0x81, 0x80 | rcode] }
        #expect(SocktainerDNSServer.shouldTryNextResolver(after: response(rcode: 2)))
        #expect(SocktainerDNSServer.shouldTryNextResolver(after: response(rcode: 5)))
        #expect(!SocktainerDNSServer.shouldTryNextResolver(after: response(rcode: 0)))
        #expect(!SocktainerDNSServer.shouldTryNextResolver(after: response(rcode: 3)))
        #expect(!SocktainerDNSServer.shouldTryNextResolver(after: [0x12]))
    }
}
