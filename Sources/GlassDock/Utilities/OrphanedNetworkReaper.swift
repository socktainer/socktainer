import Logging

/// Reaps networks left over from previous daemon sessions.
///
/// Apple Container's `vmnet` state degrades as stale networks accumulate: once enough
/// orphaned networks pile up, container-to-container routing on newly created networks
/// fails with `EHOSTUNREACH` (e.g. Supabase services can't reach the DB). glassdock
/// can retain a Docker network after `compose down` removes its containers. Clearing
/// these empty networks at startup keeps Apple network state healthy.
///
/// Safe to run only at startup: a network with live containers has a non-empty
/// `Containers` map and is kept; an empty non-built-in network at startup is necessarily
/// a leftover from a previous run (no current-session network exists yet).
enum OrphanedNetworkReaper {
    /// Built-in networks that must never be reaped.
    static let protectedNames: Set<String> = ["default"]

    /// Returns the IDs of orphaned networks (non-built-in, no attached containers).
    /// Pure decision function — the caller performs the deletions.
    static func orphanedNetworkIDs(from networks: [RESTNetworkSummary]) -> [String] {
        networks.compactMap { network in
            guard !protectedNames.contains(network.Name) else { return nil }
            let hasContainers = !(network.Containers?.isEmpty ?? true)
            return hasContainers ? nil : network.Id
        }
    }

    /// Lists networks and deletes the orphans. Best-effort: per-network failures are
    /// logged and skipped.
    static func reap(networkClient: ClientNetworkProtocol, logger: Logger) async {
        guard let networks = try? await networkClient.list(filters: nil, logger: logger) else { return }
        for id in orphanedNetworkIDs(from: networks) {
            do {
                try await networkClient.delete(id: id, logger: logger)
                logger.info("[startup] reaped orphaned network \(id)")
            } catch {
                logger.warning("[startup] failed to reap orphaned network \(id): \(error)")
            }
        }
    }
}
