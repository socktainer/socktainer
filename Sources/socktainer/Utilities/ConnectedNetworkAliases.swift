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
    // Kept apart from `aliases`, which a disconnect empties, and until `forget`: the
    // live attachments and the start-time cached IP can both be gone at cleanup.
    private var owners: [String: String] = [:]  // native ID → IP the aliases were registered under

    /// Replaces the aliases for `nativeId` on `network` and returns the replaced ones
    /// that no network still records, which are the ones safe to unregister.
    @discardableResult
    func set(nativeId: String, network: String, aliases newAliases: [String]) -> [String] {
        lock.withLock {
            let previous = aliases[nativeId]?[network] ?? []
            var byNetwork = aliases[nativeId] ?? [:]
            byNetwork[network] = newAliases.isEmpty ? nil : newAliases
            aliases[nativeId] = byNetwork.isEmpty ? nil : byNetwork
            let stillRecorded = Set(byNetwork.values.flatMap { $0 }.map(SocktainerDNSServer.normalize))
            return previous.filter { !stillRecorded.contains(SocktainerDNSServer.normalize($0)) }
        }
    }

    /// Every alias recorded for `nativeId`, on any network.
    func all(nativeId: String) -> [String] {
        lock.withLock { (aliases[nativeId] ?? [:]).values.flatMap { $0 } }
    }

    /// Records the primary IP the aliases were last registered under.
    func setOwner(nativeId: String, ip: String) {
        lock.withLock { owners[nativeId] = ip }
    }

    func owner(nativeId: String) -> String? {
        lock.withLock { owners[nativeId] }
    }

    /// Drops everything recorded for `nativeId`, once the container is gone.
    func forget(nativeId: String) {
        lock.withLock {
            aliases[nativeId] = nil
            owners[nativeId] = nil
        }
    }
}
