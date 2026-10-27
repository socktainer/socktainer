import Foundation
import Vapor

enum DNSMode: String, Sendable {
    /// One DNS forwarder sidecar container per named network, backed by SocktainerDNSServer.
    case socktainerDNS = "socktainer-dns"
    /// Resolve names through apple/container's built-in DNS.
    case appleDNS = "apple-dns"

    /// Resolves the effective mode: CLI flag > `SOCKTAINER_DNS_MODE` env > `socktainer-dns`.
    /// Throws on an invalid value in either source (fail fast, no silent fallback).
    static func resolve(
        flag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DNSMode {
        if let flag {
            return try parse(flag, source: "--dns-mode")
        }
        if let env = environment["SOCKTAINER_DNS_MODE"], !env.isEmpty {
            return try parse(env, source: "SOCKTAINER_DNS_MODE")
        }
        return .socktainerDNS
    }

    private static func parse(_ value: String, source: String) throws -> DNSMode {
        guard let mode = DNSMode(rawValue: value.lowercased()) else {
            throw DNSModeError.invalidValue(value: value, source: source)
        }
        return mode
    }
}

extension DNSMode {
    /// Startup requirements for `apple-dns` mode: a DNS domain must be configured and
    /// registered with apple/container (`container system dns create`), since only a
    /// registered domain reaches its DNS server.
    func validateStartup(
        domain: String?,
        registeredDomains: [String]
    ) throws {
        guard self == .appleDNS else { return }
        guard let domain, !domain.isEmpty else {
            throw DNSModeError.missingDomain
        }
        let wanted = domain.lowercased()
        guard registeredDomains.contains(where: { $0.lowercased() == wanted }) else {
            throw DNSModeError.unregisteredResolverDomain(domain: domain)
        }
    }
}

struct DNSModeKey: StorageKey {
    typealias Value = DNSMode
}

struct DNSDomainKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// Daemon-wide DNS resolution mode; `socktainer-dns` when unset.
    var dnsMode: DNSMode {
        storage[DNSModeKey.self] ?? .socktainerDNS
    }

    /// The DNS domain configured in apple/container's system config, when set.
    var dnsDomain: String? {
        storage[DNSDomainKey.self]
    }
}

enum DNSModeError: Error, CustomStringConvertible {
    case invalidValue(value: String, source: String)
    case missingDomain
    case unregisteredResolverDomain(domain: String)

    var description: String {
        switch self {
        case .invalidValue(let value, let source):
            "invalid DNS mode '\(value)' (from \(source)): expected 'socktainer-dns' or 'apple-dns'"
        case .missingDomain:
            "--dns-mode apple-dns requires a DNS domain in the system config (config.toml [dns] domain); see https://github.com/apple/container/blob/main/docs/networking.md"
        case .unregisteredResolverDomain(let domain):
            "--dns-mode apple-dns requires the DNS domain '\(domain)' to be registered with apple/container; see https://github.com/apple/container/blob/main/docs/networking.md"
        }
    }
}
