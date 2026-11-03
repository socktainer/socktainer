import Foundation

/// An IPv4 DNS upstream (host and UDP port) that the embedded DNS server forwards
/// non-container names to.
struct DNSUpstream: Equatable {
    let host: String
    let port: Int

    static let defaultPort = 53

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case invalidHost(String)
        case invalidPort(String)
        case unusableAddress(String)

        var description: String {
            switch self {
            case .empty:
                return "value is empty; expected <ipv4>[:port]"
            case .invalidHost(let host):
                return "'\(host)' is not an IPv4 address (hostnames and IPv6 are not supported); expected <ipv4>[:port]"
            case .unusableAddress(let host):
                return "'\(host)' cannot be used as a DNS upstream (unspecified or broadcast address)"
            case .invalidPort(let port):
                return "'\(port)' is not a valid port; expected a number between 1 and 65535"
            }
        }
    }

    /// Result of resolving the upstream override from the CLI flag and environment.
    struct Resolution: Equatable {
        /// The configured override, or `nil` to use gateway auto-detection.
        let upstream: DNSUpstream?
        /// A message to log when an ignored value was found.
        let warning: String?
    }

    static let environmentKey = "SOCKTAINER_DNS_UPSTREAM"

    /// Parses `host` or `host:port`, where `host` is an IPv4 literal and `port` is 1-65535.
    static func parse(_ value: String) throws -> DNSUpstream {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        // IPv6 literals ("::1", "[::1]:53") would otherwise split at the first colon and be
        // misreported as a bad port.
        if trimmed.hasPrefix("[") || trimmed.filter({ $0 == ":" }).count > 1 {
            throw ParseError.invalidHost(trimmed)
        }

        let hostPart: String
        let port: Int
        if let colon = trimmed.firstIndex(of: ":") {
            hostPart = String(trimmed[..<colon])
            let portPart = String(trimmed[trimmed.index(after: colon)...])
            // ASCII digits only, so "+53", "-1" and "5 3" are rejected.
            guard !portPart.isEmpty, portPart.allSatisfy({ $0.isASCII && $0.isNumber }),
                let parsed = Int(portPart), (1...65535).contains(parsed)
            else { throw ParseError.invalidPort(portPart) }
            port = parsed
        } else {
            hostPart = trimmed
            port = defaultPort
        }

        var addr = in_addr()
        guard inet_pton(AF_INET, hostPart, &addr) == 1 else { throw ParseError.invalidHost(hostPart) }
        // 0.0.0.0 would loop back into our own listener; 255.255.255.255 is broadcast.
        guard addr.s_addr != 0, addr.s_addr != UInt32.max else { throw ParseError.unusableAddress(hostPart) }
        // Store the canonical dotted-quad: Darwin's inet_pton accepts leading zeros ("01.2.3.4"),
        // and pointsAtSelf compares the first octet as text.
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            throw ParseError.invalidHost(hostPart)
        }
        return DNSUpstream(host: String(cString: buffer), port: port)
    }

    /// Whether forwarding to this upstream would reach the embedded DNS server itself
    /// on the server's own port, causing a forwarding loop. The server binds 0.0.0.0, so that is
    /// any loopback address (127.0.0.0/8) or any address in `localAddresses` (the host's
    /// interface addresses and vmnet gateways).
    func pointsAtSelf(dnsPort: Int, localAddresses: Set<String> = []) -> Bool {
        guard port == dnsPort else { return false }
        if host.split(separator: ".").first == "127" { return true }
        return localAddresses.contains(host)
    }

    /// The upstream to use once a configured override has been checked against the running server.
    enum Selection: Equatable {
        /// The override is usable as configured.
        case configured(DNSUpstream)
        /// The override points at this server; use the default network's gateway instead.
        case gatewayFallback(DNSUpstream)
        /// The override points at this server and the gateway is unknown or points at it too;
        /// use the built-in default.
        case builtInFallback(gatewayPointsAtSelf: Bool)
    }

    /// Chooses between a configured override and its fallbacks. `gateway` is the default network's
    /// gateway (nil if it could not be read); it is treated as a host address in addition to
    /// `localAddresses`, since its vmnet bridge may not exist yet.
    static func select(override: DNSUpstream, gateway: String?, dnsPort: Int, localAddresses: Set<String>) -> Selection {
        var local = localAddresses
        if let gateway {
            local.insert(gateway)
        }
        guard override.pointsAtSelf(dnsPort: dnsPort, localAddresses: local) else { return .configured(override) }
        guard let gateway else { return .builtInFallback(gatewayPointsAtSelf: false) }
        let fallback = DNSUpstream(host: gateway, port: defaultPort)
        if fallback.pointsAtSelf(dnsPort: dnsPort, localAddresses: local) {
            return .builtInFallback(gatewayPointsAtSelf: true)
        }
        return .gatewayFallback(fallback)
    }

    /// IPv4 addresses currently assigned to this host's interfaces, in canonical dotted-quad form.
    static func localIPv4Addresses() -> Set<String> {
        var result: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                result.insert(String(cString: buffer))
            }
        }
        return result
    }

    /// Applies precedence: CLI value > environment variable > `nil` (auto-detect).
    /// An invalid CLI value is expected to be rejected at startup; if one reaches here
    /// it is ignored with a warning like an invalid environment value.
    static func resolve(cliValue: String?, environment: [String: String]) -> Resolution {
        var warning: String?
        if let cliValue {
            do {
                return Resolution(upstream: try parse(cliValue), warning: nil)
            } catch {
                warning = "Ignoring invalid --dns-upstream: \(error)"
            }
        }
        if let raw = environment[environmentKey],
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                return Resolution(upstream: try parse(raw), warning: warning)
            } catch {
                warning = "Ignoring invalid \(environmentKey): \(error) — using default network gateway"
            }
        }
        return Resolution(upstream: nil, warning: warning)
    }
}
