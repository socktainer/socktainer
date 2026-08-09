import ContainerizationOCI
import Foundation

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
        fallbackRootDescriptor: Descriptor? = nil,
        leaseReconciler: any ContainerImageLeaseReconciling =
            RegisteredContainerImageLeaseReconciler()
    ) async {
        let cached = await ContainerInfoCache.shared.get(id: hexId)
        let labels = cached?.labels ?? fallbackLabels
        let rootDescriptor = cached?.rootDescriptor ?? fallbackRootDescriptor
        let dockerName = await DockerContainerMetadataStore.shared.name(nativeID: nativeId)

        if let dnsServer {
            ContainerAliasCleanup.unregisterAllAliases(
                nativeId: nativeId,
                logicalName: dockerName,
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
                    name: dockerName,
                    labels: labels
                ))
        }
        await ContainerInfoCache.shared.remove(id: hexId)
        await RestartPolicyOverrideStore.shared.remove(id: hexId)
        await PublishedPortManagerRegistry.shared.close(nativeID: nativeId)
        try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeId)
        if let rootDescriptor {
            await leaseReconciler.reconcile(rootDescriptor: rootDescriptor)
        }
    }
}
