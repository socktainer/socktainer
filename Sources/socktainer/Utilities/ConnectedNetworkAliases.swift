import Foundation

/// Aliases given through `POST /networks/{id}/connect`, per container and network.
///
/// Apple Container can't change a running container's attachments, so a connect to a
/// network the container is already on can only add DNS names. Create-time aliases live
/// in the `socktainer.dns.names` label; these live in memory only, like the DNS registry
/// they feed, so a daemon restart drops both.
final class ConnectedNetworkAliases: @unchecked Sendable {
    static let shared = ConnectedNetworkAliases()

    private let lock = NSLock()
    private var aliases: [String: [String: [String]]] = [:]  // native ID → network → aliases

    /// Replaces the aliases for `nativeId` on `network` and returns the ones replaced.
    @discardableResult
    func set(nativeId: String, network: String, aliases newAliases: [String]) -> [String] {
        lock.withLock {
            let previous = aliases[nativeId]?[network] ?? []
            var byNetwork = aliases[nativeId] ?? [:]
            byNetwork[network] = newAliases.isEmpty ? nil : newAliases
            aliases[nativeId] = byNetwork.isEmpty ? nil : byNetwork
            return previous
        }
    }

    /// Every alias recorded for `nativeId`, on any network.
    func all(nativeId: String) -> [String] {
        lock.withLock { (aliases[nativeId] ?? [:]).values.flatMap { $0 } }
    }

    /// Drops everything recorded for `nativeId`, once the container is gone.
    func forget(nativeId: String) {
        lock.withLock { aliases[nativeId] = nil }
    }
}
