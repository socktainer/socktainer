import ContainerResource
import Foundation
import Logging
import Vapor

/// Reconciles containers that were already running when Socktainer booted.
///
/// Their original process wait handles belonged to the previous daemon, so the
/// normal exit observer cannot be restored. Polling Apple state gives recovered
/// containers a bounded cleanup path: stale listeners, DNS and health state are
/// retired after a natural exit, and disappeared `--rm`-style objects lose their
/// durable Docker metadata.
actor RecoveredContainerLifecycleMonitor {
    private struct Tracked: Sendable {
        let nativeID: String
        let hexID: String
        var logicalName: String
        var labels: [String: String]
        var ip: String?
        var absentSince: Date?
    }

    private let client: ClientContainerProtocol
    private let portManager: PublishedPortManager
    private let dnsServer: SocktainerDNSServer
    private let healthManager: HealthCheckManager
    private let logger: Logger
    private let interval: Duration
    private var tracked: [String: Tracked] = [:]
    private var task: Task<Void, Never>?

    init(
        client: ClientContainerProtocol,
        portManager: PublishedPortManager,
        dnsServer: SocktainerDNSServer,
        healthManager: HealthCheckManager,
        logger: Logger,
        interval: Duration = .seconds(1)
    ) {
        self.client = client
        self.portManager = portManager
        self.dnsServer = dnsServer
        self.healthManager = healthManager
        self.logger = logger
        self.interval = interval
    }

    func start(containers: [ContainerSnapshot]) async {
        for container in containers where container.status == .running {
            await recoverRunningContainer(container)
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func shutdown() {
        task?.cancel()
        task = nil
        tracked.removeAll()
    }

    func pollOnce() async {
        let current: [ContainerSnapshot]
        do {
            current = try await client.list(showAll: true, filters: [:])
        } catch {
            logger.warning("Recovered-container lifecycle poll failed: \(error)")
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        do {
            try await DockerContainerMetadataStore.shared.reconcile(
                existingNativeIDs: Set(byID.keys)
            )
        } catch {
            logger.warning("Docker metadata reconciliation failed: \(error)")
        }
        // Continuously discover managed running containers. This provides
        // publication retry after slow address assignment and after Apple state
        // temporarily disappears/reappears without a Socktainer restart.
        for container in current where container.status == .running {
            if tracked[container.id] == nil {
                await recoverRunningContainer(container)
            }
        }
        for (nativeID, item) in tracked {
            if let current = byID[nativeID], current.status == .running {
                var refreshed = item
                refreshed.logicalName = await DockerContainerMetadataStore.shared.name(
                    nativeID: nativeID
                )
                refreshed.labels = ContainerImageIdentity.dockerLabels(for: current)
                refreshed.ip = ContainerStartRoute.dnsAttachmentIP(in: current)
                refreshed.absentSince = nil
                tracked[nativeID] = refreshed
                if refreshed.logicalName != item.logicalName || refreshed.ip != item.ip {
                    ContainerAliasCleanup.unregisterAllAliases(
                        nativeId: nativeID,
                        logicalName: item.logicalName,
                        labels: item.labels,
                        cachedIP: item.ip,
                        dnsServer: dnsServer
                    )
                    await ContainerStartRoute.registerDNSAliasesOnResume(
                        container: current,
                        dnsServer: dnsServer,
                        logger: logger
                    )
                }
                // A non-empty native field means Apple's legacy forwarder still
                // owns these host listeners. Do not create a competing listener;
                // stop/start performs the persisted migration first.
                if current.configuration.publishedPorts.isEmpty {
                    do {
                        try await portManager.reconcile(container: current)
                    } catch {
                        logger.warning(
                            "Recovered-container port reconciliation for \(item.logicalName) will retry: \(error)"
                        )
                    }
                }
                continue
            }

            if byID[nativeID] == nil {
                guard let absentSince = item.absentSince else {
                    var absent = item
                    absent.absentSince = Date()
                    tracked[nativeID] = absent
                    continue
                }
                guard Date().timeIntervalSince(absentSince) >= 10 * 60 else {
                    continue
                }
            }

            await portManager.close(nativeID: nativeID)
            await healthManager.stop(containerId: nativeID)
            let currentName =
                await DockerContainerMetadataStore.shared.entry(nativeID: nativeID)?.name
                ?? item.logicalName
            ContainerAliasCleanup.unregisterAllAliases(
                nativeId: nativeID,
                logicalName: currentName,
                labels: item.labels,
                cachedIP: item.ip,
                dnsServer: dnsServer
            )
            await ContainerRestartState.shared.reset(id: nativeID)

            if byID[nativeID] == nil {
                await ContainerInfoCache.shared.remove(id: item.hexID)
                await RestartPolicyOverrideStore.shared.remove(id: item.hexID)
                try? await DockerContainerMetadataStore.shared.remove(
                    nativeID: nativeID
                )
            }
            tracked.removeValue(forKey: nativeID)
            logger.info(
                "Reconciled recovered container \(item.logicalName) after it stopped"
            )
        }
    }

    /// Restores all daemon-owned state for a running native object. The method is
    /// deliberately idempotent so startup seeds and containers first discovered
    /// after a transient Apple service outage use the same recovery transaction.
    private func recoverRunningContainer(_ container: ContainerSnapshot) async {
        guard !ClientContainerService.isDNSSidecar(container) else { return }

        do {
            try await DockerContainerMetadataStore.shared.adopt(
                nativeID: container.id,
                name: container.id,
                publishedPorts: container.configuration.publishedPorts
            )
        } catch {
            logger.error("Failed to adopt Docker metadata for \(container.id): \(error)")
            return
        }

        let logicalName = await DockerContainerMetadataStore.shared.name(
            nativeID: container.id
        )
        let labels = ContainerImageIdentity.dockerLabels(for: container)
        let ip = ContainerStartRoute.dnsAttachmentIP(in: container)
        await ContainerInfoCache.shared.set(
            hexId: DockerContainerID.hexId(for: container),
            nativeId: container.id,
            image: ContainerImageIdentity.requestedReference(for: container),
            labels: labels,
            ip: ip,
            rootDescriptor: container.configuration.image.descriptor
        )
        if await DockerContainerMetadataStore.shared.entry(nativeID: container.id)?
            .autoRemove == true
        {
            await ContainerInfoCache.shared.markAutoRemove(
                hexId: DockerContainerID.hexId(for: container),
                nativeId: container.id
            )
        }
        await ContainerStartRoute.registerDNSAliasesOnResume(
            container: container,
            dnsServer: dnsServer,
            logger: logger
        )

        if let json = container.configuration.labels[HealthCheckManager.healthcheckLabel],
            let config = try? JSONDecoder().decode(
                HealthcheckConfig.self,
                from: Data(json.utf8)
            ),
            HealthCheckManager.parseTest(config.Test) != nil
        {
            await healthManager.start(containerId: container.id, config: config)
        }

        if container.configuration.publishedPorts.isEmpty {
            do {
                try await portManager.reconcile(container: container)
            } catch {
                logger.warning(
                    "Recovered-container port reconciliation for \(logicalName) will retry: \(error)"
                )
            }
        } else {
            logger.warning(
                "Container \(logicalName) still uses Apple's legacy port forwarder; stop/start it once to migrate publication without recreating the container"
            )
        }

        tracked[container.id] = Tracked(
            nativeID: container.id,
            hexID: DockerContainerID.hexId(for: container),
            logicalName: logicalName,
            labels: labels,
            ip: ip,
            absentSince: nil
        )
    }
}

struct RecoveredContainerLifecycleHandler: LifecycleHandler {
    let monitor: RecoveredContainerLifecycleMonitor

    func shutdownAsync(_ application: Application) async {
        await monitor.shutdown()
    }
}
