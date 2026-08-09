import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import SocktainerDNSImage
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

    @Test("unregisterIfOwned removes a hostname registered to the expected IP")
    func unregisterIfOwnedRemovesMatch() {
        let server = SocktainerDNSServer()
        server.register(hostname: "redis", ip: "192.168.1.20")
        server.unregisterIfOwned(hostname: "redis", expectedIP: "192.168.1.20")
        #expect(server.listEntries()["redis"] == nil)
    }

    @Test("unregisterIfOwned leaves a hostname registered to a different IP untouched")
    func unregisterIfOwnedSkipsMismatch() {
        let server = SocktainerDNSServer()
        server.register(hostname: "redis", ip: "192.168.1.99")
        server.unregisterIfOwned(hostname: "redis", expectedIP: "192.168.1.20")
        #expect(server.listEntries()["redis"] == "192.168.1.99")
    }

    @Test("unregisterIfOwned strips a CIDR suffix from expectedIP, matching register's parsing")
    func unregisterIfOwnedStripsCIDRSuffix() {
        let server = SocktainerDNSServer()
        server.register(hostname: "db", ip: "192.168.1.5")
        server.unregisterIfOwned(hostname: "db", expectedIP: "192.168.1.5/24")
        #expect(server.listEntries()["db"] == nil)
    }

    @Test("unregisterIfOwned on an unregistered hostname is a no-op")
    func unregisterIfOwnedUnknownIsNoOp() {
        let server = SocktainerDNSServer()
        server.unregisterIfOwned(hostname: "nonexistent", expectedIP: "192.168.1.20")  // must not crash
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
        if let p = port {
            #expect(p != 19800)  // must have fallen back
            #expect(p > 19800 && p < 19805)
        }
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

// MARK: - DNS query behaviour

/// Sends a minimal DNS query (one question per `names` entry) via UDP and returns the RCODE.
private func dnsRcode(type: UInt16, names: [String], port: Int) -> UInt8? {
    guard
        let response = sendDnsQuery(makeDnsQuery(names: names, type: type, edns0: false), port: port),
        response.count >= 4
    else { return nil }
    return response[3] & 0x0F
}

/// Builds a DNS query packet (ID 0x1234, RD=1): one question per `names` entry
/// (QDCOUNT = names.count), optionally with an EDNS0 OPT additional record
/// (ARCOUNT=1, UDP payload 4096) like real resolvers send.
private func makeDnsQuery(names: [String], type: UInt16, edns0: Bool) -> [UInt8] {
    func qnameBytes(_ name: String) -> [UInt8] {
        var qname = [UInt8]()
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            qname.append(UInt8(bytes.count))
            qname.append(contentsOf: bytes)
        }
        qname.append(0)
        return qname
    }

    var packet = [UInt8]()
    packet += [0x12, 0x34, 0x01, 0x00]  // ID + RD=1 query
    packet += [UInt8(names.count >> 8), UInt8(names.count & 0xFF)]  // QDCOUNT
    packet += [0x00, 0x00]  // ANCOUNT=0
    packet += [0x00, 0x00]  // NSCOUNT=0
    if edns0 {
        packet += [0x00, 0x01]  // ARCOUNT=1
    } else {
        packet += [0x00, 0x00]  // ARCOUNT=0
    }
    for name in names {
        packet += qnameBytes(name)
        packet += [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]  // QTYPE + QCLASS IN
    }
    if edns0 {
        // EDNS0 OPT record: root name, TYPE=41, CLASS=4096 (UDP payload), TTL=0, RDLEN=0
        packet += [0x00, 0x00, 0x29, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }
    return packet
}

/// Sends raw query bytes via UDP to 127.0.0.1:port and returns the raw response.
/// Retries up to 5 times with 50 ms gaps to handle the race between Thread.detachNewThread
/// and the server loop reaching recvfrom(). Returns nil only if all attempts time out.
private func sendDnsQuery(_ packet: [UInt8], port: Int) -> [UInt8]? {
    var dst = sockaddr_in()
    dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    dst.sin_family = sa_family_t(AF_INET)
    dst.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, "127.0.0.1", &dst.sin_addr)

    for attempt in 0..<5 {
        if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { continue }
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let sent = packet.withUnsafeBytes { ptr in
            withUnsafePointer(to: &dst) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, ptr.baseAddress!, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { continue }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        if n >= 12 { return Array(buf[0..<n]) }
    }
    return nil
}

/// Sends an EDNS0-OPT query and returns the response's ARCOUNT and the bytes remaining
/// after the question and answer sections. Both are 0 for a well-formed response — an
/// echoed OPT record or trailing bytes would make them nonzero.
private func dnsResponseTail(type: UInt16, names: [String], port: Int) -> (arcount: Int, remaining: Int)? {
    guard
        let response = sendDnsQuery(makeDnsQuery(names: names, type: type, edns0: true), port: port),
        response.count >= 12
    else { return nil }
    let qd = Int((UInt16(response[4]) << 8) | UInt16(response[5]))
    let an = Int((UInt16(response[6]) << 8) | UInt16(response[7]))
    let arcount = Int((UInt16(response[10]) << 8) | UInt16(response[11]))
    var pos = 12
    func skipName() {
        while pos < response.count {
            let len = Int(response[pos])
            pos += 1
            if len == 0 { break }
            if (len & 0xC0) == 0xC0 {
                pos += 1
                break
            }  // compression pointer (2 bytes total)
            pos += len
        }
    }
    for _ in 0..<qd {
        skipName()
        pos += 4
    }
    for _ in 0..<an {
        skipName()
        guard pos + 10 <= response.count else { break }
        let rdlen = Int((UInt16(response[pos + 8]) << 8) | UInt16(response[pos + 9]))
        pos += 10 + rdlen
    }
    return (arcount, response.count - pos)
}

@Suite("SocktainerDNSServer — query behaviour")
struct SocktainerDNSQueryTests {

    @Test("A query for registered single-label name returns RCODE 0 (NOERROR)")
    func aQueryKnownNameReturnsNoerror() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19700, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        server.register(hostname: "supabase_db_supabase", ip: "192.168.67.3")
        let rcode = dnsRcode(type: 1, names: ["supabase_db_supabase"], port: port)
        #expect(rcode == 0, "A for known name must succeed (RCODE=0)")
    }

    @Test("A query for unknown single-label name returns local NXDOMAIN (RCODE 3)")
    func aQueryUnknownNameReturnsNxdomain() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19710, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        // Warmup: register a dummy entry — the lock acquisition gives the server thread time to start.
        server.register(hostname: "_warmup", ip: "127.0.0.1")
        let rcode = dnsRcode(type: 1, names: ["no-such-container"], port: port)
        #expect(rcode == 3, "A for unknown single-label name must return NXDOMAIN without forwarding to 1.1.1.1")
    }

    @Test("AAAA query for single-label name returns NODATA (RCODE 0, no answers)")
    func aaaaQuerySingleLabelReturnsNodata() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19720, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        server.register(hostname: "db", ip: "192.168.67.3")
        // NODATA is RCODE=0 with zero answer records; the test checks RCODE only.
        let rcode = dnsRcode(type: 28, names: ["db"], port: port)
        #expect(rcode == 0, "AAAA for single-label name must return NODATA (RCODE=0), not NXDOMAIN from 1.1.1.1")
    }

    @Test("AAAA query for unknown single-label name returns NODATA (RCODE 0)")
    func aaaaQueryUnknownSingleLabelReturnsNodata() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19730, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        server.register(hostname: "_warmup", ip: "127.0.0.1")
        let rcode = dnsRcode(type: 28, names: ["unknown-svc"], port: port)
        #expect(rcode == 0, "AAAA for unknown single-label name must return NODATA, never forward to 1.1.1.1")
    }

    @Test("Query with QDCOUNT > 1 returns FORMERR (RCODE 1)")
    func qdcountGreaterThanOneReturnsFormerr() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19770, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }

        // Two questions in one query — RFC 9619: must be refused with FORMERR.
        let rcode = dnsRcode(type: 1, names: ["redis", "db"], port: port)
        #expect(rcode == 1, "QDCOUNT > 1 must be answered with FORMERR (RCODE=1)")
    }

    // Regression: NS & AR sections should be dropped when their count is set to 0.
    @Test("A query with EDNS0 OPT for a registered name returns a well-formed response")
    func aQueryWithOPTForRegisteredNameReturnsWellFormedResponse() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19740, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        server.register(hostname: "redis", ip: "192.168.1.10")

        guard let tail = dnsResponseTail(type: 1, names: ["redis"], port: port) else {
            Issue.record("No response for EDNS0 A query")
            return
        }
        #expect(tail.arcount == 0, "response must not echo the query's OPT record")
        #expect(tail.remaining == 0, "no bytes may remain after the question and answer sections")
    }

    @Test("AAAA query with EDNS0 OPT for a single-label name returns a well-formed NODATA")
    func aaaaQueryWithOPTForSingleLabelReturnsWellFormedNodata() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19750, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }
        server.register(hostname: "db", ip: "192.168.67.3")

        guard let tail = dnsResponseTail(type: 28, names: ["db"], port: port) else {
            Issue.record("No response for EDNS0 AAAA query")
            return
        }
        #expect(tail.arcount == 0, "response must not echo the query's OPT record")
        #expect(tail.remaining == 0, "no bytes may remain after the question and answer sections")
    }

    @Test("A query with EDNS0 OPT for an unknown single-label name returns a well-formed NXDOMAIN")
    func aQueryWithOPTForUnknownSingleLabelReturnsWellFormedNxdomain() throws {
        let server = SocktainerDNSServer()
        guard let port = server.start(preferredPort: 19760, maxAttempts: 5) else {
            Issue.record("Could not bind DNS server port")
            return
        }

        guard let tail = dnsResponseTail(type: 1, names: ["no-such-container"], port: port) else {
            Issue.record("No response for EDNS0 A query")
            return
        }
        #expect(tail.arcount == 0, "response must not echo the query's OPT record")
        #expect(tail.remaining == 0, "no bytes may remain after the question and answer sections")
    }
}

// MARK: - EmbeddedDNSImage / SocktainerDNSImage

@Suite("EmbeddedDNSImage")
struct EmbeddedDNSImageTests {

    @Test("SocktainerDNSImage carries a gzip archive that archiveURL() materializes to disk")
    func archiveMaterializesFromEmbeddedBytes() throws {
        let data = SocktainerDNSImage.archiveData
        #expect(!data.isEmpty)
        #expect(Array(data.prefix(2)) == [0x1f, 0x8b], "embedded archive must be gzip")

        let url = try SocktainerDNSImage.archiveURL()
        #expect(try Data(contentsOf: url) == data, "materialized file must match the embedded archive")
    }

    @Test("EmbeddedDNSImage.tag matches SocktainerDNSImage.reference")
    func tagMatchesPackageReference() {
        #expect(EmbeddedDNSImage.tag == SocktainerDNSImage.reference)
        #expect(EmbeddedDNSImage.tag == "socktainer-dns:embedded", "image tag must match what NetworkDNSManager registers")
    }

    // Regression for the permanent-failure-caching bug (CodeRabbit review): a transient
    // error in perform() must not poison every future call. After a failure the gate resets
    // so the next caller can retry — without this, DNS sidecar creation never recovers
    // from a momentary resource error without a process restart.
    @Test("ImportGate.ensureOnce resets after failure so the next caller can retry")
    func importGateResetsAfterFailure() async throws {
        struct ImportError: Error {}
        let gate = EmbeddedDNSImage.ImportGate()

        // First call: fails.
        await #expect(throws: ImportError.self) {
            try await gate.ensureOnce { throw ImportError() }
        }

        // Second call: must succeed — gate must have cleared the failed task.
        let retryCount = ActorCounter()
        let image = try await gate.ensureOnce {
            await retryCount.increment()
            return makeTestImage()
        }
        #expect(await retryCount.value == 1, "gate must allow retry after a prior failure")
        #expect(image.reference == EmbeddedDNSImage.tag, "gate must return the image produced by the retried perform")
    }

    @Test("ImportGate.ensureOnce returns the image produced by perform")
    func importGateReturnsPerformImage() async throws {
        let gate = EmbeddedDNSImage.ImportGate()
        let image = try await gate.ensureOnce { makeTestImage(reference: EmbeddedDNSImage.tag) }
        #expect(image.reference == EmbeddedDNSImage.tag)
    }

    // Regression for the concurrent first-use race (Finding #1 in CodeRabbit review):
    // without ImportGate, two networks starting simultaneously both missed the
    // ClientImage.get check and both called load(), nondeterministic on a fresh store.
    // This test proves that ImportGate.ensureOnce coalesces concurrent callers so the
    // perform closure executes exactly once even when two tasks race through it.
    @Test("ImportGate.ensureOnce executes perform exactly once under concurrent callers")
    func importGateCoalescesConcurrentCallers() async throws {
        let gate = EmbeddedDNSImage.ImportGate()
        let callCount = ActorCounter()

        // Start two tasks concurrently; both will race into ensureOnce.
        async let t1: ClientImage = gate.ensureOnce {
            await callCount.increment()
            // Brief yield so the second task has a chance to arrive while the first is
            // in-flight, proving the "in-flight task" branch of ensureOnce is exercised.
            try await Task.sleep(nanoseconds: 10_000_000)
            return makeTestImage()
        }
        async let t2: ClientImage = gate.ensureOnce {
            await callCount.increment()
            try await Task.sleep(nanoseconds: 10_000_000)
            return makeTestImage()
        }
        let r1 = try await t1
        let r2 = try await t2

        let count = await callCount.value
        #expect(count == 1, "perform must execute exactly once — concurrent callers must coalesce, not each run the body")
        #expect(r1.reference == r2.reference, "coalesced callers must all receive the single leader's image")
    }
}

private func makeTestImage(reference: String = EmbeddedDNSImage.tag) -> ClientImage {
    ClientImage(
        description: ImageDescription(
            reference: reference,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
    )
}

// MARK: - Helpers

private actor ActorCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - firstNamedNetwork (plain docker run --network parity)

@Suite("ContainerCreateRoute.firstNamedNetwork")
struct FirstNamedNetworkTests {

    @Test("Compose EndpointsConfig key is returned when present")
    func composePath() {
        let result = ContainerCreateRoute.firstNamedNetwork(
            endpointsConfigKeys: ["myapp_default"],
            networkMode: nil
        )
        #expect(result == "myapp_default")
    }

    @Test("HostConfig.NetworkMode is returned when EndpointsConfig is absent")
    func networkModePath() {
        let result = ContainerCreateRoute.firstNamedNetwork(
            endpointsConfigKeys: [],
            networkMode: "user-net"
        )
        #expect(result == "user-net")
    }

    @Test("EndpointsConfig takes precedence over NetworkMode")
    func endpointsConfigWins() {
        let result = ContainerCreateRoute.firstNamedNetwork(
            endpointsConfigKeys: ["compose-net"],
            networkMode: "mode-net"
        )
        #expect(result == "compose-net")
    }

    @Test("Reserved modes return nil")
    func reservedModesReturnNil() {
        for mode in ["default", "bridge", "host", "none"] {
            let result = ContainerCreateRoute.firstNamedNetwork(
                endpointsConfigKeys: [],
                networkMode: mode
            )
            #expect(result == nil, "mode '\(mode)' must not trigger DNS setup")
        }
    }

    @Test("Empty networkMode returns nil")
    func emptyNetworkModeReturnsNil() {
        let result = ContainerCreateRoute.firstNamedNetwork(
            endpointsConfigKeys: [],
            networkMode: ""
        )
        #expect(result == nil)
    }

    @Test("No config at all returns nil")
    func noConfigReturnsNil() {
        let result = ContainerCreateRoute.firstNamedNetwork(
            endpointsConfigKeys: [],
            networkMode: nil
        )
        #expect(result == nil)
    }

    @Test("Reserved names in EndpointsConfig return nil")
    func reservedEndpointsConfigKeysReturnNil() {
        for mode in ["default", "bridge", "host", "none"] {
            let result = ContainerCreateRoute.firstNamedNetwork(
                endpointsConfigKeys: [mode],
                networkMode: nil
            )
            #expect(result == nil, "EndpointsConfig key '\(mode)' must not trigger DNS setup")
        }
    }

    @Test("EndpointsConfig skips reserved and returns first valid key")
    func endpointsConfigSkipsReserved() {
        let result = ContainerCreateRoute.firstNamedNetwork(
            endpointsConfigKeys: ["default", "user-net"],
            networkMode: nil
        )
        #expect(result == "user-net", "must skip 'default' and return the first non-reserved key")
    }
}

// MARK: - sidecarNetwork (DNS forwarder ensured on container start, not only create)

@Suite("ContainerStartRoute.sidecarNetwork")
struct SidecarNetworkTests {

    @Test("Returns the first user-defined network the container is attached to")
    func returnsNamedNetwork() {
        let result = ContainerStartRoute.sidecarNetwork(configuredNetworks: ["stackdemo_default"], roleLabel: nil)
        #expect(result == "stackdemo_default")
    }

    @Test("Reserved networks return nil")
    func reservedNetworksReturnNil() {
        for net in ["default", "bridge", "host", "none"] {
            let result = ContainerStartRoute.sidecarNetwork(configuredNetworks: [net], roleLabel: nil)
            #expect(result == nil, "network '\(net)' has no DNS forwarder and must not trigger ensure")
        }
    }

    @Test("Skips reserved and returns the first user-defined network")
    func skipsReserved() {
        let result = ContainerStartRoute.sidecarNetwork(configuredNetworks: ["default", "user-net"], roleLabel: nil)
        #expect(result == "user-net")
    }

    @Test("No networks returns nil")
    func noNetworksReturnsNil() {
        #expect(ContainerStartRoute.sidecarNetwork(configuredNetworks: [], roleLabel: nil) == nil)
    }

    @Test("Empty network names are skipped")
    func emptyNamesSkipped() {
        #expect(ContainerStartRoute.sidecarNetwork(configuredNetworks: [""], roleLabel: nil) == nil)
    }

    @Test("A DNS sidecar container returns nil even on a user network")
    func dnsSidecarReturnsNil() {
        let result = ContainerStartRoute.sidecarNetwork(
            configuredNetworks: ["stackdemo_default"],
            roleLabel: NetworkDNSManager.dnsRole
        )
        #expect(result == nil, "a DNS sidecar must not ensure another sidecar for its own network")
    }
}

// MARK: - ContainerStartRoute.dnsAttachmentIP (cache/cleanup IP must match the registered IP)

@Suite("ContainerStartRoute.dnsAttachmentIP")
struct DNSAttachmentIPTests {

    @Test("Skips a reserved first attachment and returns the named network's IP")
    func skipsReservedFirstAttachment() throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "web-1",
            networks: [(network: "bridge", ip: "192.168.65.10"), (network: "stackdemo_default", ip: "192.168.65.20")],
            labels: [:]
        )
        let result = ContainerStartRoute.dnsAttachmentIP(in: snapshot)
        #expect(result == "192.168.65.20", "must match the IP dnsServer.register(hostname:ip:) is actually called with")
    }

    @Test("A single named network returns its own IP")
    func singleNamedNetwork() throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web-1", ip: "192.168.65.20", network: "stackdemo_default", labels: [:])
        #expect(ContainerStartRoute.dnsAttachmentIP(in: snapshot) == "192.168.65.20")
    }

    @Test("Only reserved networks returns nil")
    func onlyReservedNetworksReturnsNil() throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web-1", ip: "192.168.65.10", network: "bridge", labels: [:])
        #expect(ContainerStartRoute.dnsAttachmentIP(in: snapshot) == nil)
    }

    @Test("Nil snapshot returns nil")
    func nilSnapshotReturnsNil() {
        #expect(ContainerStartRoute.dnsAttachmentIP(in: nil) == nil)
    }
}

// MARK: - ContainerStartRoute.registerDNSAliasesOnResume (daemon-restart re-registration)

@Suite("ContainerStartRoute.registerDNSAliasesOnResume")
struct RegisterDNSAliasesOnResumeTests {

    @Test("Re-registers on a named network even when the first attachment is reserved")
    func reRegistersPastReservedFirstAttachment() throws {
        let container = try makeContainerSnapshot(
            nativeId: "web-1",
            networks: [(network: "bridge", ip: "192.168.65.10"), (network: "stackdemo_default", ip: "192.168.65.20")],
            labels: [:]
        )
        let dnsServer = SocktainerDNSServer()
        ContainerStartRoute.registerDNSAliasesOnResume(container: container, dnsServer: dnsServer, logger: Logger(label: "test"))
        #expect(dnsServer.listEntries()["web-1"] == "192.168.65.20")
    }

    @Test("A container on only reserved networks is not registered")
    func onlyReservedNetworksSkipsRegistration() throws {
        let container = try makeContainerSnapshot(nativeId: "web-1", ip: "192.168.65.10", network: "bridge", labels: [:])
        let dnsServer = SocktainerDNSServer()
        ContainerStartRoute.registerDNSAliasesOnResume(container: container, dnsServer: dnsServer, logger: Logger(label: "test"))
        #expect(dnsServer.listEntries().isEmpty)
    }

    @Test("Also registers socktainer.dns.names and Compose service/project aliases")
    func registersAllAliases() throws {
        let container = try makeContainerSnapshot(
            nativeId: "db-1",
            ip: "192.168.65.20",
            network: "stackdemo_default",
            labels: [
                "socktainer.dns.names": "postgres,pg",
                "com.docker.compose.service": "db",
                "com.docker.compose.project": "stackdemo",
            ]
        )
        let dnsServer = SocktainerDNSServer()
        ContainerStartRoute.registerDNSAliasesOnResume(container: container, dnsServer: dnsServer, logger: Logger(label: "test"))
        let entries = dnsServer.listEntries()
        #expect(entries["db-1"] == "192.168.65.20")
        #expect(entries["postgres"] == "192.168.65.20")
        #expect(entries["pg"] == "192.168.65.20")
        #expect(entries["db"] == "192.168.65.20")
        #expect(entries["db.stackdemo"] == "192.168.65.20")
    }
}
