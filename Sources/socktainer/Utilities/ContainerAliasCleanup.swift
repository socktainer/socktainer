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

        func unregisterIfOwned(_ hostname: String) {
            let registered = dnsServer.listEntries()[SocktainerDNSServer.normalize(hostname)]
            if registered != nil, registered != cachedIP { return }
            dnsServer.unregister(hostname: hostname)
        }

        if !nativeId.isEmpty {
            unregisterIfOwned(nativeId)
        }
        if let namesLabel = labels["socktainer.dns.names"] {
            for name in namesLabel.split(separator: ",").map(String.init) where !name.isEmpty {
                unregisterIfOwned(name)
            }
        }
        if let serviceName = labels["com.docker.compose.service"], !serviceName.isEmpty {
            unregisterIfOwned(serviceName)
            if let projectName = labels["com.docker.compose.project"], !projectName.isEmpty {
                unregisterIfOwned("\(serviceName).\(projectName)")
            }
        }
    }
}
