import Foundation

/// Unregisters a container's DNS aliases (name, `socktainer.dns.names`, Compose
/// service/project) — used by the `--rm` auto-remove paths, which never receive a
/// DELETE for `ContainerDeleteRoute` to react to.
///
/// `cachedIP` nil means ownership can't be confirmed, so nothing is touched: unregistering
/// blind risks yanking a live peer's identically-named alias, worse than a stale leftover.
enum ContainerAliasCleanup {
    static func unregisterAllAliases(
        nativeId: String,
        labels: [String: String],
        cachedIP: String?,
        dnsServer: SocktainerDNSServer
    ) {
        guard let cachedIP else { return }

        if !nativeId.isEmpty {
            dnsServer.unregisterIfOwned(hostname: nativeId, expectedIP: cachedIP)
        }
        if let namesLabel = labels["socktainer.dns.names"] {
            for name in namesLabel.split(separator: ",").map(String.init) where !name.isEmpty {
                dnsServer.unregisterIfOwned(hostname: name, expectedIP: cachedIP)
            }
        }
        if let serviceName = labels["com.docker.compose.service"], !serviceName.isEmpty {
            dnsServer.unregisterIfOwned(hostname: serviceName, expectedIP: cachedIP)
            if let projectName = labels["com.docker.compose.project"], !projectName.isEmpty {
                dnsServer.unregisterIfOwned(hostname: "\(serviceName).\(projectName)", expectedIP: cachedIP)
            }
        }
    }
}
