import Foundation

/// Unregisters a container's DNS aliases (name, `socktainer.dns.names`, Compose
/// service/project, network-connect aliases) — used by the `--rm` auto-remove
/// paths, which never receive a DELETE for `ContainerDeleteRoute` to react to.
///
/// `cachedIP` nil means ownership can't be confirmed, so nothing is touched: unregistering
/// blind risks yanking a live peer's identically-named alias, worse than a stale leftover.
/// Network-connect aliases fall back to the owner recorded when they were registered.
enum ContainerAliasCleanup {
    static func unregisterAllAliases(
        nativeId: String,
        labels: [String: String],
        cachedIP: String?,
        dnsServer: SocktainerDNSServer
    ) {
        if let connectedOwner = cachedIP ?? ConnectedNetworkAliases.shared.owner(nativeId: nativeId) {
            for name in ConnectedNetworkAliases.shared.all(nativeId: nativeId) {
                dnsServer.unregisterIfOwned(hostname: name, expectedIP: connectedOwner)
            }
        }
        guard let cachedIP else { return }
        for name in configuredNames(nativeId: nativeId, labels: labels) {
            dnsServer.unregisterIfOwned(hostname: name, expectedIP: cachedIP)
        }
    }

    /// Unregisters network-connect aliases a connect replaced or a disconnect removed,
    /// keeping any that the container's start-time names also register.
    static func unregisterConnectedAliases(
        _ names: [String],
        nativeId: String,
        labels: [String: String],
        owner: String,
        dnsServer: SocktainerDNSServer
    ) {
        let configured = Set(configuredNames(nativeId: nativeId, labels: labels).map(SocktainerDNSServer.normalize))
        for name in names where !configured.contains(SocktainerDNSServer.normalize(name)) {
            dnsServer.unregisterIfOwned(hostname: name, expectedIP: owner)
        }
    }

    /// The names `ContainerStartRoute` registers from the container's id and raw labels.
    static func configuredNames(nativeId: String, labels: [String: String]) -> [String] {
        var names: [String] = []
        if !nativeId.isEmpty {
            names.append(nativeId)
        }
        if let namesLabel = labels["socktainer.dns.names"] {
            names += namesLabel.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        if let serviceName = labels["com.docker.compose.service"], !serviceName.isEmpty {
            names.append(serviceName)
            if let projectName = labels["com.docker.compose.project"], !projectName.isEmpty {
                names.append("\(serviceName).\(projectName)")
            }
        }
        return names
    }
}
