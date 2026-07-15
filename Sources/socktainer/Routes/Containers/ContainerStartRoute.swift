import ContainerAPIClient
import ContainerResource
import Foundation
import Logging
import Vapor

struct ContainerStartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/start", use: ContainerStartRoute.handler(client: client))
    }
}

struct ContainerStartQuery: Content {
    /// Override the key sequence for detaching a container
    let detachKeys: String?
}

extension ContainerStartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in

            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerStartQuery.self)
            let detachKeys = query.detachKeys

            let preStartSnapshot: ContainerSnapshot?
            do {
                preStartSnapshot = try await client.getContainer(id: id)
            } catch ClientContainerError.notFound {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            }

            do {
                guard let container = preStartSnapshot else {
                    throw Abort(.notFound, reason: "No such container: \(id)")
                }

                await ContainerRestartState.shared.reset(id: container.id)

                await ContainerStartRoute.ensureDNSSidecarBeforeStart(for: container, req: req)

                // If container is already running, return success (Docker CLI behavior)
                if container.status == .running {
                    req.logger.debug("Container \(id) is already running")
                } else {
                    // Try to start the container
                    try await client.start(id: id, detachKeys: detachKeys)
                    req.logger.debug("Started container \(id)")
                }

            } catch {
                // Check if error indicates container is already running/bootstrapped
                let errorMessage = error.localizedDescription
                let isAlreadyRunning =
                    errorMessage.contains("booted") || errorMessage.contains("expected to be in created state") || errorMessage.contains("invalidState")
                    || errorMessage.contains("already running")

                guard isAlreadyRunning else {
                    req.logger.error("Failed to start container \(id): \(error)")
                    throw Abort(.internalServerError, reason: "Failed to start container: \(error)")
                }
                req.logger.debug("Container \(id) was already running or bootstrapped")
            }

            let startedSnapshot = await ContainerStartRoute.performPostStartSetup(
                id: id,
                client: client,
                dnsServer: req.application.storage[SocktainerDNSServerKey.self],
                healthManager: req.application.storage[HealthCheckManagerKey.self],
                logger: req.logger
            )

            let metadataSnapshot = startedSnapshot ?? preStartSnapshot
            // Derive the canonical 64-char Docker ID once here so the cache and all
            // lifecycle events use the same stable id the create event returned.
            let eventId = metadataSnapshot.map { DockerContainerID.hexId(for: $0) } ?? id
            if let snap = metadataSnapshot {
                // Store under canonical hexId so later lookups by the Docker hex ID always
                // hit, regardless of whether /start was called by name or short ID.
                let containerIP = ContainerStartRoute.dnsAttachmentIP(in: startedSnapshot)
                await ContainerInfoCache.shared.set(
                    hexId: eventId,
                    nativeId: snap.id,
                    image: snap.configuration.image.reference,
                    labels: LabelNormalization.restore(snap.configuration.labels),
                    ip: containerIP
                )
            }

            guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else {
                return .noContent
            }

            // moby logs per-volume "mount" events while setting up the container's mounts,
            // before the "start" event (daemon/volumes_unix.go). Same pragmatism as the
            // ungated "start" below: a redundant /start re-emits them.
            if let snap = metadataSnapshot {
                await VolumeMountEvents.broadcastMounts(for: snap, containerId: eventId, broadcaster: broadcaster)
            }

            // Emit "start" on every successful /start. We intentionally do NOT gate this on
            // "did this call transition the container to running": for a foreground `docker run`,
            // the attach route bootstraps and starts the container BEFORE /start is invoked, so
            // /start sees it already running — indistinguishable from a redundant `docker start`.
            // Gating dropped the start (and die) events for the common `docker run` case, so we
            // accept a possible extra event on the rare redundant `docker start` instead.
            let event = DockerEvent.simpleEvent(
                id: eventId,
                type: "container",
                status: "start",
                image: metadataSnapshot?.configuration.image.reference ?? "",
                name: metadataSnapshot?.id ?? id,
                labels: LabelNormalization.restore(metadataSnapshot?.configuration.labels ?? [:])
            )
            await broadcaster.broadcast(event)

            // Observe the container process exit to fire the "die" event.
            // Runs as a detached background task — the start route returns immediately.
            if let snap = metadataSnapshot {
                let restartPolicy = RestartPolicyManager.decode(from: snap.configuration.labels)
                let generation = await ContainerRestartState.shared.currentGeneration(id: snap.id)
                await ContainerStartRoute.armRestartObserver(
                    nativeId: snap.id,
                    eventId: eventId,
                    image: snap.configuration.image.reference,
                    name: snap.id,
                    labels: LabelNormalization.restore(snap.configuration.labels),
                    ip: ContainerStartRoute.dnsAttachmentIP(in: startedSnapshot),
                    refreshCache: false,
                    restartPolicy: restartPolicy,
                    generation: generation,
                    broadcaster: broadcaster,
                    dnsServer: req.application.storage[SocktainerDNSServerKey.self],
                    healthManager: req.application.storage[HealthCheckManagerKey.self],
                    client: client,
                    logger: req.logger
                )
            }

            return .noContent
        }
    }

    /// Awaits the container's init process exit, fires the "die" event, and — unless it was
    /// created with `--rm` — honors `HostConfig.RestartPolicy` by restarting it and re-arming
    /// this observer for the next lifecycle. Runs as a detached background task.
    static func observeExit(
        nativeId: String,
        eventId: String,
        image: String,
        name: String,
        labels: [String: String],
        broadcaster: EventBroadcaster,
        dnsServer: SocktainerDNSServer?,
        healthManager: HealthCheckManager?,
        restartPolicy: RestartPolicy?,
        client: ClientContainerProtocol,
        logger: Logger,
        generation: Int
    ) {
        Task.detached {
            let startedAt = Date()

            // Await the authoritative exit code recorded by the start() background waiter
            // once the init process exits. Using the store's continuation-based wait (rather
            // than client.wait's timed grace-poll) means the die event always carries the
            // real code, even under load — no `?? 0` fallback race.
            let code = await ContainerExitCodeStore.shared.waitForCode(id: nativeId)

            // A redundant /start also arms a second observer on this nativeId; bail before a
            // stale one broadcasts its own "die" for an exit the current observer already owns.
            guard await ContainerRestartState.shared.isCurrent(id: nativeId, generation: generation) else { return }

            let executionDuration = Date().timeIntervalSince(startedAt)

            // moby unmounts the container's volumes during exit cleanup, before logging
            // "die" (daemon/monitor.go → daemon.Cleanup → container.UnmountVolumes). The
            // snapshot is re-fetched here; a --rm container already reaped by Apple
            // Container resolves to nil and skips its unmount events.
            let exitSnapshot = (try? await client.getContainer(id: nativeId)) ?? nil
            if let exitSnapshot {
                await VolumeMountEvents.broadcastUnmounts(for: exitSnapshot, containerId: eventId, broadcaster: broadcaster)
            }

            var attrs = labels
            attrs["exitCode"] = String(code)
            // moby's die event carries the run duration in whole seconds (daemon/monitor.go).
            attrs["execDuration"] = String(Int(executionDuration))
            let dieEvent = DockerEvent.simpleEvent(
                id: eventId, type: "container", status: "die",
                image: image, name: name, labels: attrs
            )
            await broadcaster.broadcast(dieEvent)

            // moby fires `destroy` right after `die` for `--rm` containers. Apple Container
            // reaps them itself (no DELETE arrives), so emit it here. consumeAutoRemove both
            // gates on the --rm flag and dedups against the foreground attach path, so a
            // container attached in the foreground does not get a second destroy.
            if await ContainerInfoCache.shared.consumeAutoRemove(id: nativeId) {
                await ContainerAutoRemoveCleanup.perform(
                    hexId: eventId,
                    nativeId: nativeId,
                    fallbackImage: image,
                    fallbackLabels: labels,
                    dnsServer: dnsServer,
                    broadcaster: broadcaster
                )
                await ContainerRestartState.shared.reset(id: nativeId)
                return
            }

            let explicitlyStopped = await ContainerRestartState.shared.consumeExplicitlyStopped(id: nativeId)
            let nextAttemptNumber = await ContainerRestartState.shared.count(id: nativeId) + 1
            // The armed policy is the immutable create-time label; a docker update landing
            // while the container runs must govern THIS exit, so the override is read now.
            let effectivePolicy = await RestartPolicyOverrideStore.shared.get(id: eventId) ?? restartPolicy
            let willRestart =
                effectivePolicy.map {
                    RestartPolicyManager.shouldRestart(
                        policy: $0, exitCode: code, attempt: nextAttemptNumber, hasBeenManuallyStopped: explicitlyStopped)
                } ?? false

            // Staying stopped: moby tears down a container's network sandbox (and its DNS
            // resolution) on every exit, not just --rm. Mirror that here, after the generation
            // guard above so a stale, superseded observer can't unregister a live,
            // already-restarted container's alias.
            guard willRestart else {
                if let dnsServer {
                    let cached = await ContainerInfoCache.shared.get(id: nativeId)
                    ContainerAliasCleanup.unregisterAllAliases(
                        nativeId: nativeId,
                        labels: cached?.labels ?? labels,
                        cachedIP: cached?.ip,
                        dnsServer: dnsServer
                    )
                }
                return
            }

            await ContainerRestartState.shared.markPendingRestart(id: nativeId)
            let backoffDelay = await ContainerRestartState.shared.nextBackoffDelayNanoseconds(
                id: nativeId, ranAtLeast10Seconds: executionDuration >= 10)
            try? await Task.sleep(nanoseconds: backoffDelay)

            guard await ContainerRestartState.shared.isCurrent(id: nativeId, generation: generation) else {
                await ContainerRestartState.shared.clearPendingRestart(id: nativeId)
                logger.info("restart-policy: aborting stale restart for \(nativeId) — a newer lifecycle has taken over")
                return
            }
            // A docker update or docker stop landing during the backoff sleep (up to
            // 60s) must cancel the restart decided under the old inputs.
            let policyAfterBackoff = await RestartPolicyOverrideStore.shared.get(id: eventId) ?? restartPolicy
            let stoppedDuringBackoff = await ContainerRestartState.shared.consumeExplicitlyStopped(id: nativeId)
            let stillWantsRestart =
                policyAfterBackoff.map {
                    RestartPolicyManager.shouldRestart(
                        policy: $0, exitCode: code, attempt: nextAttemptNumber,
                        hasBeenManuallyStopped: explicitlyStopped || stoppedDuringBackoff)
                } ?? false
            guard stillWantsRestart else {
                await ContainerRestartState.shared.clearPendingRestart(id: nativeId)
                logger.info("restart-policy: aborting restart for \(nativeId) — policy or stop state changed during backoff")
                return
            }
            // Record the attempt only once we're actually about to restart — a concurrent
            // /start or /restart landing during the backoff sleep above must not inflate
            // RestartCount for a restart that the generation check just aborted.
            let attempt = await ContainerRestartState.shared.nextAttempt(id: nativeId)
            do {
                try await client.start(id: nativeId, detachKeys: nil)
            } catch {
                await ContainerRestartState.shared.clearPendingRestart(id: nativeId)
                logger.warning("restart-policy: failed to restart \(nativeId) (attempt \(attempt)): \(error)")
                return
            }
            await ContainerRestartState.shared.clearPendingRestart(id: nativeId)

            let restartedSnapshot = await ContainerStartRoute.performPostStartSetup(
                id: nativeId, client: client, dnsServer: dnsServer, healthManager: healthManager, logger: logger
            )

            // Refresh the cache before broadcasting "start" so a listener that reacts to the
            // event by reading ContainerInfoCache always sees the restarted container's new IP.
            await ContainerStartRoute.armRestartObserver(
                nativeId: nativeId,
                eventId: eventId,
                image: image,
                name: name,
                labels: labels,
                ip: ContainerStartRoute.dnsAttachmentIP(in: restartedSnapshot),
                refreshCache: restartedSnapshot != nil,
                restartPolicy: restartPolicy,
                generation: generation,
                broadcaster: broadcaster,
                dnsServer: dnsServer,
                healthManager: healthManager,
                client: client,
                logger: logger
            )
            if let snap = restartedSnapshot ?? exitSnapshot {
                await VolumeMountEvents.broadcastMounts(for: snap, containerId: eventId, broadcaster: broadcaster)
            }
            await broadcaster.broadcast(
                DockerEvent.simpleEvent(id: eventId, type: "container", status: "start", image: image, name: name, labels: labels)
            )
        }
    }

    /// Refreshes `ContainerInfoCache` (when `refreshCache` is true) and arms `observeExit`
    /// to watch the container's next exit. Shared by `/start`, `/restart`, and the internal
    /// restart-policy restart so all three leave the same cache/observer state behind.
    static func armRestartObserver(
        nativeId: String,
        eventId: String,
        image: String,
        name: String,
        labels: [String: String],
        ip: String?,
        refreshCache: Bool,
        restartPolicy: RestartPolicy?,
        generation: Int,
        broadcaster: EventBroadcaster,
        dnsServer: SocktainerDNSServer?,
        healthManager: HealthCheckManager?,
        client: ClientContainerProtocol,
        logger: Logger
    ) async {
        if refreshCache {
            await ContainerInfoCache.shared.set(hexId: eventId, nativeId: nativeId, image: image, labels: labels, ip: ip)
        }

        // A restart's internal stop step (ClientContainerService.restart) marks the container
        // explicitly-stopped; clear it here so the new observer doesn't mistake a manual
        // restart for a stop that should suppress restart-policy enforcement on the next exit.
        _ = await ContainerRestartState.shared.consumeExplicitlyStopped(id: nativeId)

        ContainerStartRoute.observeExit(
            nativeId: nativeId, eventId: eventId, image: image, name: name, labels: labels,
            broadcaster: broadcaster, dnsServer: dnsServer, healthManager: healthManager,
            restartPolicy: restartPolicy, client: client, logger: logger, generation: generation
        )
    }

    /// Waits briefly for the container's network IP, re-registers its DNS entries, and
    /// (re-)starts its healthcheck loop. Shared by the HTTP handler and the internal
    /// restart-policy restart, so both leave a restarted container's DNS/health state current.
    static func performPostStartSetup(
        id: String,
        client: ClientContainerProtocol,
        dnsServer: SocktainerDNSServer?,
        healthManager: HealthCheckManager?,
        logger: Logger
    ) async -> ContainerSnapshot? {
        // Resolve through getContainer: clients commonly start containers by the hex ID
        // returned from create, which the native lookup rejects. Retry up to 5 times
        // (500 ms total): Apple Container may return the container before the vmnet IP
        // is assigned, leaving networks[] empty on the first fetch.
        var startedSnapshot = (try? await client.getContainer(id: id)) ?? nil
        if startedSnapshot?.networks.isEmpty == true {
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let refreshed = try? await client.getContainer(id: id),
                    !refreshed.networks.isEmpty
                {
                    startedSnapshot = refreshed
                    break
                }
            }
        }

        if let dnsServer,
            let snapshot = startedSnapshot,
            !ClientContainerService.isDNSSidecar(snapshot)
        {
            // Register only on a network that has a DNS forwarder sidecar — same reserved set
            // as sidecarNetwork. On reserved networks (default/bridge/host/none) there is no
            // forwarder so any registration would be unreachable; skip entirely if none of the
            // container's attachments qualify, rather than falling back to the first attachment.
            if let ip = ContainerStartRoute.dnsAttachmentIP(in: snapshot) {
                if !snapshot.id.isEmpty {
                    dnsServer.register(hostname: snapshot.id, ip: ip)
                    logger.info("[dns] registered container name '\(snapshot.id)' → \(ip)")
                }

                // Names stored at create time (Compose service aliases via socktainer.dns.names)
                if let namesLabel = snapshot.configuration.labels["socktainer.dns.names"] {
                    for name in namesLabel.split(separator: ",").map(String.init) where !name.isEmpty {
                        dnsServer.register(hostname: name, ip: ip)
                    }
                }

                // Register Docker Compose service names so that containers in the same
                // project can resolve each other by service name (e.g. "db") or the
                // project-qualified form (e.g. "db.myapp").
                //
                // The qualified form (service.project) matches Docker's own DNS behaviour
                // and avoids collisions when multiple Compose projects run concurrently.
                if let serviceName = snapshot.configuration.labels["com.docker.compose.service"],
                    !serviceName.isEmpty
                {
                    dnsServer.register(hostname: serviceName, ip: ip)
                    if let projectName = snapshot.configuration.labels["com.docker.compose.project"],
                        !projectName.isEmpty
                    {
                        dnsServer.register(hostname: "\(serviceName).\(projectName)", ip: ip)
                        logger.info("[dns] registered compose aliases '\(serviceName)' and '\(serviceName).\(projectName)' → \(ip)")
                    } else {
                        logger.info("[dns] registered compose alias '\(serviceName)' → \(ip)")
                    }
                }
            }
        }

        // Kick off the healthcheck probe loop if a healthcheck label is set.
        // The label was JSON-encoded by the create route from body.Healthcheck.
        // Reuse startedSnapshot (already resolved via client.getContainer, which handles
        // hex IDs) rather than calling ContainerClient().get(id:) directly — the raw call
        // would fail when the client sends the hex digest instead of the Apple Container name.
        // Use snapshot.id (the native Apple Container name) as the HealthCheckManager key so
        // it matches the lookup in ContainerInspectRoute and ContainerListRoute, which read
        // health via container.id (the native name, not the hex digest).
        if let healthManager,
            let snapshot = startedSnapshot,
            let labelValue = snapshot.configuration.labels[HealthCheckManager.healthcheckLabel],
            let healthcheck = try? JSONDecoder().decode(HealthcheckConfig.self, from: Data(labelValue.utf8))
        {
            await healthManager.start(containerId: snapshot.id, config: healthcheck)
        }

        return startedSnapshot
    }

    static func ensureDNSSidecarBeforeStart(for container: ContainerSnapshot, req: Request) async {
        guard container.status != .running,
            let dnsManager = req.application.storage[NetworkDNSManagerKey.self],
            let network = sidecarNetwork(
                configuredNetworks: container.configuration.networks.map { $0.network },
                roleLabel: container.configuration.labels[NetworkDNSManager.roleLabel]
            )
        else { return }
        do {
            _ = try await dnsManager.ensureDNSContainer(networkId: network)
        } catch {
            req.logger.warning("Could not ensure DNS sidecar for \(network) on start: \(error)")
        }
    }

    static func sidecarNetwork(configuredNetworks: [String], roleLabel: String?) -> String? {
        if roleLabel == NetworkDNSManager.dnsRole { return nil }
        let reserved: Set<String> = ["default", "bridge", "host", "none"]
        return configuredNetworks.first { !$0.isEmpty && !reserved.contains($0) }
    }

    /// The IP DNS aliases are registered under — the first non-reserved network
    /// attachment. Every cache/cleanup site (ContainerInfoCache.ip, ContainerDeleteRoute)
    /// must derive its IP the same way, or unregisterIfOwned's ownership check silently
    /// fails to match on multi-network containers.
    static func dnsAttachmentIP(in snapshot: ContainerSnapshot?) -> String? {
        let reservedNetworks: Set<String> = ["default", "bridge", "host", "none"]
        return snapshot?.networks.first { !$0.network.isEmpty && !reservedNetworks.contains($0.network) }?
            .ipv4Address.address.description
    }

    /// Re-registers a resumed container's DNS aliases (name, `socktainer.dns.names`,
    /// Compose service/project) — called once per still-running container when
    /// Socktainer starts, since SocktainerDNSServer's registry is in-memory and lost
    /// across daemon restarts. Uses dnsAttachmentIP so a container whose first network
    /// attachment happens to be reserved (e.g. bridge) still gets re-registered on its
    /// named network, instead of being skipped entirely.
    static func registerDNSAliasesOnResume(container: ContainerSnapshot, dnsServer: SocktainerDNSServer, logger: Logger) {
        guard let ip = ContainerStartRoute.dnsAttachmentIP(in: container) else { return }

        dnsServer.register(hostname: container.id, ip: ip)
        if let namesLabel = container.configuration.labels["socktainer.dns.names"] {
            for name in namesLabel.split(separator: ",").map(String.init) where !name.isEmpty {
                dnsServer.register(hostname: name, ip: ip)
            }
        }
        if let serviceName = container.configuration.labels["com.docker.compose.service"], !serviceName.isEmpty {
            dnsServer.register(hostname: serviceName, ip: ip)
            if let projectName = container.configuration.labels["com.docker.compose.project"], !projectName.isEmpty {
                dnsServer.register(hostname: "\(serviceName).\(projectName)", ip: ip)
            }
        }
        logger.info("[dns] re-registered '\(container.id)' → \(ip) on resume")
    }
}
