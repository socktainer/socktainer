import ContainerAPIClient
import ContainerizationExtras
import ContainerizationOCI
import Foundation

/// Chooses http vs https for registry traffic.
///
/// apple/container 1.3.0 removed `RequestScheme.auto` (and its `isInternalHost` helper), making
/// `https` the only default; the CLI compensates with an explicit `--scheme` flag. socktainer
/// cannot: the Docker Engine API has nowhere to carry a per-request scheme, and a daemon-wide
/// flag would be the wrong granularity. Docker itself treats localhost and private ranges as
/// insecure registries by default, so reproducing the old heuristic here is what keeps
/// `docker push localhost:5000/img` working — the behavior socktainer's clients expect.
enum RegistryScheme {
    /// Deliberate deviation from the removed upstream heuristic: `Reference.domain` includes the
    /// port ("localhost:5000"), and upstream compared it against the bare string "localhost", so
    /// `.auto` in fact resolved a ported local registry to https. Stripping the port first is
    /// what actually makes local registries reachable.
    static func scheme(forHost host: String, internalDnsDomain: String?) -> RequestScheme {
        let bareHost = stripPort(from: host)

        if bareHost == "localhost" {
            return .http
        }

        if let internalDnsDomain, bareHost.hasSuffix(".\(internalDnsDomain)") {
            return .http
        }

        guard let ipv4Address = try? IPv4Address(bareHost) else {
            return .https
        }

        let ipv4Value = ipv4Address.value

        // 10.0.0.0/8 and 127.0.0.0/8 are private CIDRs.
        if (ipv4Value & 0xff00_0000 == 0x0a00_0000) || (ipv4Value & 0xff00_0000 == 0x7f00_0000) {
            return .http
        }

        // 192.168.0.0/16 is a private CIDR.
        if ipv4Value & 0xffff_0000 == 0xc0a8_0000 {
            return .http
        }

        // 172.16.0.0/12 is a private CIDR.
        if ipv4Value & 0xfff0_0000 == 0xac10_0000 {
            return .http
        }

        return .https
    }

    /// Resolves from a full image reference; falls back to `.https` when the reference carries no
    /// domain (a bare `nginx` resolves to Docker Hub).
    static func scheme(forReference reference: String, internalDnsDomain: String?) -> RequestScheme {
        guard let parsed = try? Reference.parse(reference), let domain = parsed.domain else {
            return .https
        }
        return scheme(forHost: domain, internalDnsDomain: internalDnsDomain)
    }

    /// Strips a trailing ":<port>" (or the brackets of an IPv6 literal) so the host component
    /// alone is classified. A suffix only counts as a port when it is entirely digits, so plain
    /// domains with colons in unexpected places are left untouched.
    private static func stripPort(from host: String) -> String {
        if host.hasPrefix("[") {
            if let closeBracket = host.firstIndex(of: "]") {
                return String(host[host.index(after: host.startIndex)..<closeBracket])
            }
            return host
        }

        guard let lastColon = host.lastIndex(of: ":") else {
            return host
        }

        let portCandidate = host[host.index(after: lastColon)...]
        guard !portCandidate.isEmpty, portCandidate.allSatisfy(\.isNumber) else {
            return host
        }

        return String(host[host.startIndex..<lastColon])
    }
}
