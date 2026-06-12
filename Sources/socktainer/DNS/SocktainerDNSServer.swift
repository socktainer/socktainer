import Darwin
import Foundation
import Logging
import Vapor

struct SocktainerDNSServerKey: StorageKey {
    typealias Value = SocktainerDNSServer
}

/// UDP DNS server that resolves container service names and forwards unknown queries to 1.1.1.1.
///
/// Runs on 0.0.0.0:2054 (covers all interfaces including vmnet gateways).
/// Port 2053 is reserved by Apple Container's own DNS handler.
/// Container names are registered after start via register(hostname:ip:) and
/// unregistered on container removal via unregister(hostname:).
final class SocktainerDNSServer: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [UInt8]] = [:]  // normalized hostname → 4-byte IPv4
    private var log = Logger(label: "socktainer.dns")

    func register(hostname: String, ip: String) {
        guard let addr = Self.parseIPv4(ip) else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        entries[key] = addr
        log.info("[dns] registered \(key) → \(ip)")
    }

    func unregister(hostname: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        if entries.removeValue(forKey: key) != nil {
            log.info("[dns] unregistered \(key)")
        }
    }

    func listEntries() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.mapValues { ip in "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])" }
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

        // Dispatch each query to a thread so the recvfrom loop is never blocked.
        // forwardToUpstream() waits up to 2s for 1.1.1.1; without async dispatch
        // every pending query times out while the loop is stuck on a slow upstream.
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

            DispatchQueue.global(qos: .userInitiated).async {
                guard let response = self.handleQuery(packet) else { return }
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

    private func handleQuery(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 12 else { return nil }

        // Only handle standard queries (QR=0, OPCODE=0)
        let flags = (UInt16(packet[2]) << 8) | UInt16(packet[3])
        guard (flags & 0x8000) == 0, (flags & 0x7800) == 0 else { return nil }

        guard let (qname, qtype, _) = parseQuestion(packet, offset: 12) else {
            return forwardToUpstream(packet)
        }

        let normalized = Self.normalize(qname)

        if qtype == 1 {  // A record
            lock.lock()
            let ip = entries[normalized]
            lock.unlock()
            if let ip {
                log.info("[dns] A \(normalized) → \(ip[0]).\(ip[1]).\(ip[2]).\(ip[3]) (local)")
                return buildAResponse(packet: packet, ip: ip)
            }
        } else if qtype == 28 {  // AAAA — return NODATA for known hosts (prevents musl NXDOMAIN bug)
            lock.lock()
            let known = entries[normalized] != nil
            lock.unlock()
            if known {
                return buildNodataResponse(packet: packet)
            }
        }

        if !normalized.contains(".") {
            log.info("[dns] \(normalized) not in table, forwarding to 1.1.1.1")
        }
        return forwardToUpstream(packet)
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

    private func buildAResponse(packet: [UInt8], ip: [UInt8]) -> [UInt8] {
        var response = packet
        let rd = (UInt16(packet[2]) << 8 | UInt16(packet[3])) & 0x0100
        let rflags: UInt16 = 0x8400 | rd  // QR=1, AA=1
        response[2] = UInt8(rflags >> 8)
        response[3] = UInt8(rflags & 0xFF)
        response[6] = 0
        response[7] = 1  // ANCOUNT=1
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
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
        let rd = (UInt16(packet[2]) << 8 | UInt16(packet[3])) & 0x0100
        let rflags: UInt16 = 0x8400 | rd
        response[2] = UInt8(rflags >> 8)
        response[3] = UInt8(rflags & 0xFF)
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
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
        upstream.sin_port = UInt16(53).bigEndian
        inet_pton(AF_INET, "1.1.1.1", &upstream.sin_addr)

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
}
