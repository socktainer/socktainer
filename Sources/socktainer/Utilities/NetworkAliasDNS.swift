import ContainerResource
import Foundation

/// DNS names, aliases, search domains and ndots for the `apple-dns` mode, which relies on
/// apple/container's built-in DNS fed by the aliases registered on each network attachment.
enum NetworkAliasDNS {

    private static let reservedNetworks: Set<String> = ["default", "bridge", "host", "none"]

    /// Reserved Docker network names — they never get a per-network DNS zone and never
    /// count as a named network.
    static func isReservedNetwork(_ name: String) -> Bool {
        reservedNetworks.contains(name.lowercased())
    }

    /// True when `name` is already fully qualified: a trailing dot, or ending in
    /// `.{dnsDomain}`. Such a name is used as it is, never expanded with the zone.
    static func isFQDN(_ name: String, dnsDomain: String) -> Bool {
        let canonical = AttachmentOptions.canonicalHostname(name)
        return name.hasSuffix(".") || canonical.hasSuffix(".\(dnsDomain.lowercased())")
    }

    static func zone(_ network: String, dnsDomain: String) -> String {
        "\(network.lowercased()).\(dnsDomain)"
    }

    /// The aliases as one attachment registers them: each qualified with the per-network
    /// zone unless it is already fully qualified, the first occurrence kept.
    static func qualifiedAliases(
        _ aliases: [String], network: String, dnsDomain: String, hostname: String,
        warn: (String) -> Void = { _ in }
    ) -> [String] {
        var seen: Set<String> = [AttachmentOptions.canonicalHostname(hostname)]
        var qualified: [String] = []
        for alias in aliases where !alias.isEmpty {
            let alreadyQualified = isFQDN(alias, dnsDomain: dnsDomain)
            let name = alreadyQualified ? alias : qualify(alias, network: network, dnsDomain: dnsDomain)
            guard seen.insert(AttachmentOptions.canonicalHostname(name)).inserted else { continue }
            qualified.append(name)
            if !alreadyQualified, guestMayNotExpand(alias) {
                warn(
                    "apple-dns mode: the ndots option in /etc/resolv.conf may keep this container from expanding this alias (\(alias)), use the qualified name (\(name)) in such cases"
                )
            }
        }
        return qualified
    }

    /// True when the guest resolver may not expand the name: musl expands a name only when
    /// it has fewer dots than `ndots` and otherwise looks it up as typed, while glibc falls
    /// back to the search list. A leading dot counts as a dot.
    static func guestMayNotExpand(_ name: String) -> Bool {
        name.filter { $0 == "." }.count >= 2
    }

    /// Search domains for a multi-network container: the client's existing ones first, then
    /// `<network>.<dnsDomain>` per network, then the bare `dnsDomain`, deduplicated in order.
    static func searchDomains(_ existing: [String] = [], networks: [String], dnsDomain: String) -> [String] {
        var seen = Set<String>()
        var domains: [String] = []
        for domain in existing + networks.map({ zone($0, dnsDomain: dnsDomain) }) + [dnsDomain] {
            if seen.insert(domain.lowercased()).inserted { domains.append(domain) }
        }
        return domains
    }

    /// Expands `name` into the per-network FQDN `name.<network>.<dnsDomain>`; FQDNs pass through.
    static func qualify(_ name: String, network: String, dnsDomain: String) -> String {
        guard !isFQDN(name, dnsDomain: dnsDomain) else { return name }
        return "\(name).\(zone(network, dnsDomain: dnsDomain))"
    }

    /// The `ndots:N` resolver option: max(user value, 2), or `ndots:2` when absent.
    static func ndots(from userOptions: [String]) -> String {
        guard let entry = userOptions.first(where: { $0.lowercased().hasPrefix("ndots:") }),
            let value = entry.split(separator: ":").last.flatMap({ Int($0) })
        else { return "ndots:2" }
        return "ndots:\(max(value, 2))"
    }
}
