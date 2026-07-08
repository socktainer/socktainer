import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Darwin
import Foundation
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

/// Sends a minimal DNS A or AAAA query via UDP and returns the RCODE from the response.
/// Retries up to 5 times with 50 ms gaps to handle the race between Thread.detachNewThread
/// and the server loop reaching recvfrom(). Returns nil only if all attempts time out.
private func dnsRcode(type: UInt16, name: String, port: Int) -> UInt8? {
    var qname = [UInt8]()
    for label in name.split(separator: ".") {
        let bytes = Array(label.utf8)
        qname.append(UInt8(bytes.count))
        qname.append(contentsOf: bytes)
    }
    qname.append(0)

    var packet = [UInt8]()
    packet += [0x12, 0x34, 0x01, 0x00]  // ID + RD=1 query
    packet += [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]  // QDCOUNT=1, rest 0
    packet += qname
    packet += [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]  // QTYPE + QCLASS IN

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
        if n >= 4 { return buf[3] & 0x0F }
    }
    return nil
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
        let rcode = dnsRcode(type: 1, name: "supabase_db_supabase", port: port)
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
        let rcode = dnsRcode(type: 1, name: "no-such-container", port: port)
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
        let rcode = dnsRcode(type: 28, name: "db", port: port)
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
        let rcode = dnsRcode(type: 28, name: "unknown-svc", port: port)
        #expect(rcode == 0, "AAAA for unknown single-label name must return NODATA, never forward to 1.1.1.1")
    }
}

// MARK: - EmbeddedDNSImage / SocktainerDNSImage SwiftPM resource

@Suite("EmbeddedDNSImage — SwiftPM resource")
struct EmbeddedDNSImageTests {

    @Test("SocktainerDNSImage.archiveURL resolves to an existing file")
    func archiveURLResolvesToExistingFile() {
        let url = SocktainerDNSImage.archiveURL
        #expect(url.lastPathComponent == "socktainer-dns.tar.gz")
        #expect(FileManager.default.fileExists(atPath: url.path), "tarball must be present in SwiftPM resource bundle")
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
