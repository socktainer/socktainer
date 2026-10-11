import Darwin
import Foundation
import Logging
import Vapor

struct SocktainerDNSServerKey: StorageKey {
    typealias Value = SocktainerDNSServer
}

/// UDP DNS server that resolves container service names and forwards unknown queries to
/// `upstreamHost` — the vmnet gateway resolver in production, so names resolve as on the host
/// (VPN split DNS, `/etc/resolver/*`); 1.1.1.1 only when no gateway is known.
///
/// Runs on 0.0.0.0:2054 (covers all interfaces including vmnet gateways).
/// Port 2053 is reserved by Apple Container's own DNS handler.
/// Container names are registered after start via register(hostname:ips:) and
/// unregistered on container removal via unregisterIfOwned(hostname:expectedIP:).
///
/// A container on several networks is registered once per network, as CIDRs. Every
/// network's forwarder sidecar relays to this one server, so an A query is answered with
/// the address whose subnet contains the querying sidecar's address.
final class SocktainerDNSServer: @unchecked Sendable {
    private struct Subnet: Equatable {
        let network: [UInt8]
        let prefixLength: UInt8
    }

    /// `subnet` is nil for a bare-IP registration. `owner` is the first address of the
    /// registering batch, so `unregisterIfOwned` removes all of a container's addresses.
    private struct AddressEntry {
        let ip: [UInt8]
        let subnet: Subnet?
        let owner: [UInt8]
    }

    private let lock = NSLock()
    private var entries: [String: [AddressEntry]] = [:]  // normalized hostname → addresses, first-registered first
    private var log = Logger(label: "socktainer.dns")
    private var _upstreamHost = "1.1.1.1"
    /// Upstream for non-container names. Lock-guarded: startup may set it after the
    /// server is already answering queries.
    var upstreamHost: String {
        get { lock.withLock { _upstreamHost } }
        set { lock.withLock { _upstreamHost = newValue } }
    }
    /// Upstream port; only overridden by tests, before `start(...)`.
    var upstreamPort = 53

    func register(hostname: String, ip: String) {
        register(hostname: hostname, ips: [ip])
    }

    /// Registers one container's addresses for `hostname`, each optionally a CIDR such as
    /// "192.168.1.5/24". An address replaces any entry on the same subnet (bare IPs share
    /// one slot) and is added alongside entries on other subnets.
    func register(hostname: String, ips: [String]) {
        let parsed = ips.compactMap(Self.parseIPv4WithSubnet)
        guard let owner = parsed.first?.address else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        var routes = entries[key] ?? []
        for (addr, subnet) in parsed {
            routes.removeAll { $0.subnet == subnet }
            routes.append(AddressEntry(ip: addr, subnet: subnet, owner: owner))
        }
        entries[key] = routes
        log.info("[dns] registered \(key) → \(ips.joined(separator: ", "))")
    }

    func unregister(hostname: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        if entries.removeValue(forKey: key) != nil {
            log.info("[dns] unregistered \(key)")
        }
    }

    /// Unregisters the addresses `hostname` holds for the container whose first registered
    /// address is `expectedIP` — atomically, so a concurrent re-registration between a
    /// caller's ownership check and its unregister call can't be dropped. Addresses
    /// registered by another container under the same name are left untouched.
    func unregisterIfOwned(hostname: String, expectedIP: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        guard let expected = Self.parseIPv4(expectedIP), var routes = entries[key] else { return }
        let before = routes.count
        routes.removeAll { $0.owner == expected }
        guard routes.count != before else { return }
        entries[key] = routes.isEmpty ? nil : routes
        log.info("[dns] unregistered \(key)")
    }

    /// One address per hostname, the first registered. Used for env-var rewriting at
    /// create time, which has no querying network to scope by.
    func listEntries() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.compactMapValues { routes in
            routes.first.map { Self.format($0.ip) }
        }
    }

    /// The address of `hostname` on the subnet containing `clientIP`, else the
    /// first-registered address. `hostname` must already be normalized.
    func lookupAddress(_ hostname: String, clientIP: [UInt8]) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let routes = entries[hostname] else { return nil }
        let match = routes.first { route in
            guard let subnet = route.subnet else { return false }
            return Self.networkAddress(clientIP, prefixLength: subnet.prefixLength) == subnet.network
        }
        return (match ?? routes.first)?.ip
    }

    private func hasEntry(_ hostname: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[hostname] != nil
    }

    /// Tries to bind to `preferredPort`, then `preferredPort+1`, `+2`, up to `maxAttempts`.
    /// Returns the port that was successfully bound, or nil if all attempts failed.
    /// The resolved port must be passed to NetworkDNSManager so Corefiles reference the right one.
    @discardableResult
    func start(preferredPort: Int = 2054, maxAttempts: Int = 10) -> Int? {
        for offset in 0..<maxAttempts {
            let port = preferredPort + offset
            if canBind(port: port) {
                Thread.detachNewThread { self.serverLoop(port: port) }
                return port
            }
            log.warning("[dns] port \(port) unavailable, trying \(port + 1)")
        }
        log.error("[dns] no available port in \(preferredPort)..<\(preferredPort + maxAttempts)")
        return nil
    }

    private func canBind(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func serverLoop(port: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            log.error("[dns] socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            log.error("[dns] bind() failed on port \(port): \(String(cString: strerror(errno)))")
            return
        }

        log.info("[dns] listening on 0.0.0.0:\(port)")

        var buf = [UInt8](repeating: 0, count: 512)

        // Two-tier dispatch: local lookups (in-table A/AAAA/NODATA) are answered
        // inline so the Rust DNS forwarder sidecar receives the response within
        // microseconds — before any per-task scheduling latency. Upstream queries
        // (external multi-label names that need the upstream) are still dispatched to
        // avoid blocking the recvfrom loop for the 2-second socket timeout.
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buf, buf.count, 0, sockPtr, &clientLen)
                }
            }
            guard n > 12 else { continue }

            let packet = Array(buf[0..<n])
            let capturedAddr = clientAddr
            let capturedLen = clientLen
            // For containers this is the forwarder sidecar on the network the query came from.
            let clientIP = withUnsafeBytes(of: capturedAddr.sin_addr.s_addr) { Array($0) }

            // Fast path: local resolution — answer inline without dispatch latency.
            if let local = handleLocalQuery(packet, clientIP: clientIP) {
                var addr = capturedAddr
                _ = local.withUnsafeBytes { ptr in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, ptr.baseAddress!, local.count, 0, $0, capturedLen)
                        }
                    }
                }
                continue
            }

            // Slow path: upstream query — dispatch so recvfrom stays responsive.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let response = self.handleQuery(packet, clientIP: clientIP) else { return }
                var addr = capturedAddr
                _ = response.withUnsafeBytes { ptr in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, ptr.baseAddress!, response.count, 0, $0, capturedLen)
                        }
                    }
                }
            }
        }
    }

    /// Returns a local response without touching the network. Returns nil if the query
    /// needs to be forwarded upstream, letting the caller fall through to the slow path.
    private func handleLocalQuery(_ packet: [UInt8], clientIP: [UInt8]) -> [UInt8]? {
        guard packet.count >= 12 else { return nil }
        let flags = (UInt16(packet[2]) << 8) | UInt16(packet[3])
        guard (flags & 0x8000) == 0, (flags & 0x7800) == 0 else { return nil }
        // RFC 9619: QDCOUNT > 1 is FORMERR.
        let qd = (UInt16(packet[4]) << 8) | UInt16(packet[5])
        guard qd <= 1 else { return buildFormerrResponse(packet: packet) }
        guard let (qname, qtype, questionEnd) = parseQuestion(packet, offset: 12) else { return nil }
        // Response skeleton: header + question, any additional sections dropped.
        let responsePacket = makeResponsePacket(packet, questionEnd: questionEnd)
        let normalized = Self.normalize(qname)
        let isSingleLabel = !normalized.contains(".")
        if qtype == 1 {
            if let ip = lookupAddress(normalized, clientIP: clientIP) {
                log.info("[dns] A \(normalized) → \(ip[0]).\(ip[1]).\(ip[2]).\(ip[3]) (local)")
                return buildAResponse(packet: responsePacket, ip: ip)
            }
            if isSingleLabel {
                log.info("[dns] \(normalized) not in table (local NXDOMAIN)")
                return buildNxdomainResponse(packet: responsePacket)
            }
        } else if qtype == 28 {
            if isSingleLabel { return buildNodataResponse(packet: responsePacket) }
            if hasEntry(normalized) { return buildNodataResponse(packet: responsePacket) }
        }
        // Any other single-label query type (HTTPS/SVCB/SRV/TXT/…) is answered NODATA
        // locally rather than forwarded: a single-label name has no public meaning, so
        // forwarding it upstream only invites an authoritative NXDOMAIN that poisons the
        // resolver's parallel A+AAAA lookups.
        if isSingleLabel { return buildNodataResponse(packet: responsePacket) }
        return nil
    }

    private func handleQuery(_ packet: [UInt8], clientIP: [UInt8]) -> [UInt8]? {
        guard packet.count >= 12 else { return nil }

        // Only handle standard queries (QR=0, OPCODE=0)
        let flags = (UInt16(packet[2]) << 8) | UInt16(packet[3])
        guard (flags & 0x8000) == 0, (flags & 0x7800) == 0 else { return nil }

        // QDCOUNT > 1 → FORMERR is answered in handleLocalQuery (fast path).
        guard let (qname, qtype, questionEnd) = parseQuestion(packet, offset: 12) else {
            // Malformed question — no end to strip; forward as-is.
            return forwardToUpstream(packet)
        }

        // Response skeleton: header + question, any additional sections dropped.
        let responsePacket = makeResponsePacket(packet, questionEnd: questionEnd)

        let normalized = Self.normalize(qname)

        // Single-label names are container names, not real internet domains — never forward
        // them upstream, whose authoritative NXDOMAIN can poison concurrent A+AAAA resolvers.
        let isSingleLabel = !normalized.contains(".")

        if qtype == 1 {  // A record
            if let ip = lookupAddress(normalized, clientIP: clientIP) {
                log.info("[dns] A \(normalized) → \(ip[0]).\(ip[1]).\(ip[2]).\(ip[3]) (local)")
                return buildAResponse(packet: responsePacket, ip: ip)
            }
            if isSingleLabel {
                log.info("[dns] \(normalized) not in table (local NXDOMAIN)")
                return buildNxdomainResponse(packet: responsePacket)
            }
        } else if qtype == 28 {  // AAAA — container names are IPv4-only
            // For single-label names return NODATA unconditionally; forwarding upstream
            // would yield an authoritative NXDOMAIN that poisons concurrent A+AAAA resolvers.
            if isSingleLabel { return buildNodataResponse(packet: responsePacket) }
            if hasEntry(normalized) { return buildNodataResponse(packet: responsePacket) }
        }

        // Forward without EDNS0: our 512-byte recv buffer can't hold a large response.
        return forwardToUpstream(makeQueryPacket(packet, questionEnd: questionEnd))
    }

    private func parseQuestion(_ packet: [UInt8], offset: Int) -> (String, UInt16, Int)? {
        var pos = offset
        var labels: [String] = []
        while pos < packet.count {
            let len = Int(packet[pos])
            pos += 1
            if len == 0 { break }
            if (len & 0xC0) == 0xC0 { return nil }
            guard pos + len <= packet.count else { return nil }
            labels.append(String(bytes: packet[pos..<(pos + len)], encoding: .utf8) ?? "")
            pos += len
        }
        guard pos + 4 <= packet.count else { return nil }
        let qtype = (UInt16(packet[pos]) << 8) | UInt16(packet[pos + 1])
        pos += 4
        return (labels.joined(separator: "."), qtype, pos)
    }

    /// DNS response header: QR=1, the query's RD echoed, AN/NS/AR counts zeroed.
    private func makeResponseHeader(_ packet: [UInt8]) -> [UInt8] {
        var response = Array(packet.prefix(12))
        let rd = (UInt16(packet[2]) << 8 | UInt16(packet[3])) & 0x0100
        let rflags: UInt16 = 0x8000 | rd  // QR=1
        response[2] = UInt8(rflags >> 8)
        response[3] = UInt8(rflags & 0xFF)
        response[6] = 0  // ANCOUNT=0
        response[7] = 0
        response[8] = 0  // NSCOUNT=0
        response[9] = 0
        response[10] = 0  // ARCOUNT=0
        response[11] = 0
        return response
    }

    /// Header + question skeleton shared by the answer builders (additional records
    /// dropped), so the answer lands directly after the question, where clients parse it.
    private func makeResponsePacket(_ packet: [UInt8], questionEnd: Int) -> [UInt8] {
        makeResponseHeader(packet) + Array(packet[12..<questionEnd])
    }

    /// Query skeleton forwarded upstream: header + question with any additional records
    /// (e.g. an EDNS0 OPT) dropped and other counts zeroed, so the packet stays well-formed.
    private func makeQueryPacket(_ packet: [UInt8], questionEnd: Int) -> [UInt8] {
        var query = Array(packet.prefix(12))
        query[6] = 0  // ANCOUNT=0
        query[7] = 0
        query[8] = 0  // NSCOUNT=0
        query[9] = 0
        query[10] = 0  // ARCOUNT=0
        query[11] = 0
        query += Array(packet[12..<questionEnd])
        return query
    }

    private func buildAResponse(packet: [UInt8], ip: [UInt8]) -> [UInt8] {
        var response = packet
        response[2] |= 0x04  // AA=1 (Authoritative Answer)
        response[7] = 1  // ANCOUNT=1
        response += [
            0xC0, 0x0C,  // NAME: pointer to offset 12
            0x00, 0x01,  // TYPE: A
            0x00, 0x01,  // CLASS: IN
            0x00, 0x00, 0x00, 0x1E,  // TTL: 30s
            0x00, 0x04,  // RDLENGTH: 4
            ip[0], ip[1], ip[2], ip[3],
        ]
        return response
    }

    private func buildNodataResponse(packet: [UInt8]) -> [UInt8] {
        var response = packet
        response[2] |= 0x04  // AA=1
        return response
    }

    // Non-authoritative NXDOMAIN (no AA bit) so clients retry rather than cache permanently.
    private func buildNxdomainResponse(packet: [UInt8]) -> [UInt8] {
        var response = packet
        response[3] |= 0x03  // RCODE=3 (NXDOMAIN)
        return response
    }

    // FORMERR (RCODE=1): header only, question dropped, so counts stay consistent.
    private func buildFormerrResponse(packet: [UInt8]) -> [UInt8] {
        var response = makeResponseHeader(packet)
        response[3] |= 0x01  // RCODE=1 (FORMERR)
        response[4] = 0  // QDCOUNT=0
        response[5] = 0
        return response
    }

    private func forwardToUpstream(_ packet: [UInt8]) -> [UInt8]? {
        let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sockfd >= 0 else { return nil }
        defer { Darwin.close(sockfd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var upstream = sockaddr_in()
        upstream.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        upstream.sin_family = sa_family_t(AF_INET)
        upstream.sin_port = UInt16(upstreamPort).bigEndian
        guard inet_pton(AF_INET, upstreamHost, &upstream.sin_addr) == 1 else { return nil }

        let connected = withUnsafePointer(to: &upstream) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let sent = packet.withUnsafeBytes { send(sockfd, $0.baseAddress!, packet.count, 0) }
        guard sent == packet.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 512)
        let received = recv(sockfd, &buf, buf.count, 0)
        guard received > 0 else { return nil }
        return Array(buf[0..<received])
    }

    static func normalize(_ hostname: String) -> String {
        var s = hostname.lowercased()
        while s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }

    private static func parseIPv4(_ ip: String) -> [UInt8]? {
        let bare = String(ip.split(separator: "/").first ?? ip[...])
        var addr = in_addr()
        guard inet_pton(AF_INET, bare, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    /// A bare address, or one with an invalid prefix, parses with a nil subnet.
    private static func parseIPv4WithSubnet(_ ip: String) -> (address: [UInt8], subnet: Subnet?)? {
        let parts = ip.split(separator: "/", maxSplits: 1)
        guard let first = parts.first, let addr = parseIPv4(String(first)) else { return nil }
        guard parts.count == 2, let prefixLength = UInt8(parts[1]), prefixLength <= 32 else {
            return (addr, nil)
        }
        return (addr, Subnet(network: networkAddress(addr, prefixLength: prefixLength), prefixLength: prefixLength))
    }

    private static func networkAddress(_ ip: [UInt8], prefixLength: UInt8) -> [UInt8] {
        var remaining = Int(prefixLength)
        var result = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 {
            if remaining >= 8 {
                result[i] = ip[i]
            } else if remaining > 0 {
                result[i] = ip[i] & UInt8(0xFF - (0xFF >> remaining))
            }
            remaining -= 8
        }
        return result
    }

    private static func format(_ ip: [UInt8]) -> String {
        "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
    }
}
