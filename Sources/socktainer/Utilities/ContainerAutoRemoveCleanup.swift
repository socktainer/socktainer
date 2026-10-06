import Foundation
import Logging

/// Performs the full `--rm` cleanup once `ContainerInfoCache.consumeAutoRemove` grants it:
/// DNS alias unregistration, the `destroy` event, and clearing the cache entry. Shared by the
/// three paths that observe a `--rm` container's exit directly — start, attach, attach-WS —
/// since Apple Container reaps `--rm` containers itself and no DELETE ever reaches
/// `ContainerDeleteRoute`.
enum ContainerAutoRemoveCleanup {
    static func perform(
        hexId: String,
        nativeId: String,
        fallbackImage: String,
        fallbackLabels: [String: String],
        dnsServer: SocktainerDNSServer?,
        broadcaster: EventBroadcaster?,
        removeVolumes: @Sendable ([String]) async -> Void = { names in
            await ContainerAnonymousVolumes.remove(names: names, logger: Logger(label: "socktainer.autoremove"), retries: 30)
        }
    ) async {
        let cached = await ContainerInfoCache.shared.get(id: hexId)
        let labels = cached?.labels ?? fallbackLabels
        let resolvedNativeID = cached?.nativeId ?? nativeId
        let displayName = await ContainerNameOverrideStore.shared.name(forNativeID: resolvedNativeID)

        await removeVolumes(ContainerAnonymousVolumes.names(labels: labels))

        if let dnsServer {
            ContainerAliasCleanup.unregisterAllAliases(
                nativeId: resolvedNativeID,
                displayName: displayName,
                labels: labels,
                cachedIP: cached?.ip,
                dnsServer: dnsServer
            )
        }
        if let broadcaster {
            await broadcaster.broadcast(
                ContainerAttachRoute.makeAutoRemoveEvent(
                    id: hexId,
                    image: cached?.image ?? fallbackImage,
                    name: cached?.nativeId ?? nativeId,
                    labels: labels
                ))
        }
        await ContainerInfoCache.shared.remove(id: hexId)
        do {
            try await ContainerNameOverrideStore.shared.remove(nativeID: resolvedNativeID)
        } catch {
            Logger(label: "socktainer.autoremove").error("Could not remove container name override: \(error)")
        }
        await RestartPolicyOverrideStore.shared.remove(id: hexId)
        // `--rm` containers are reaped here instead of through DELETE, so this is where their
        // die-event bookkeeping is released. It also refuses later claims: a second observer
        // still resolving the same exit would otherwise find no record and emit another `die`.
        await DieEventOwnership.shared.forget(id: cached?.nativeId ?? nativeId)
    }
}
