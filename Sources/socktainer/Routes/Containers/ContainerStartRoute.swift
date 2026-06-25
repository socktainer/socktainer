import ContainerAPIClient
import ContainerResource
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

            // Register DNS names now that the container has an IP.
            // Names were stored in the label at create time (Compose service aliases).
            // Resolve through getContainer: clients commonly start containers by
            // the hex ID returned from create, which the native lookup rejects.
            let startedSnapshot = (try? await client.getContainer(id: id)) ?? nil
            if let dnsServer = req.application.storage[SocktainerDNSServerKey.self],
                let snapshot = startedSnapshot,
                snapshot.configuration.labels[NetworkDNSManager.roleLabel] != NetworkDNSManager.dnsRole,
                let firstAttachment = snapshot.networks.first
            {
                let ip = firstAttachment.ipv4Address.address.description

                // Register the container's own name only on networks that have a DNS forwarder
                // sidecar — same reserved set as firstNamedNetwork. On reserved networks
                // (default/bridge/host/none) there is no forwarder so the registration would
                // be unreachable and is skipped entirely.
                let reservedNetworks: Set<String> = ["default", "bridge", "host", "none"]
                if !snapshot.id.isEmpty && !reservedNetworks.contains(firstAttachment.network) {
                    dnsServer.register(hostname: snapshot.id, ip: ip)
                    req.logger.info("[dns] registered container name '\(snapshot.id)' → \(ip)")
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
                        req.logger.info("[dns] registered compose aliases '\(serviceName)' and '\(serviceName).\(projectName)' → \(ip)")
                    } else {
                        req.logger.info("[dns] registered compose alias '\(serviceName)' → \(ip)")
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
            if let healthManager = req.application.storage[HealthCheckManagerKey.self],
                let snapshot = startedSnapshot,
                let labelValue = snapshot.configuration.labels[HealthCheckManager.healthcheckLabel],
                let healthcheck = try? JSONDecoder().decode(HealthcheckConfig.self, from: Data(labelValue.utf8))
            {
                await healthManager.start(containerId: snapshot.id, config: healthcheck)
            }

            let metadataSnapshot = startedSnapshot ?? preStartSnapshot
            // Derive the canonical 64-char Docker ID once here so the cache and all
            // lifecycle events use the same stable id the create event returned.
            let eventId = metadataSnapshot.map { DockerContainerID.hexId(for: $0) } ?? id
            if let snap = metadataSnapshot {
                // Store under canonical hexId so later lookups by the Docker hex ID always
                // hit, regardless of whether /start was called by name or short ID.
                let containerIP = startedSnapshot?.networks.first?.ipv4Address.address.description
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
                let nativeId = snap.id
                let dieImage = snap.configuration.image.reference
                let dieName = snap.id
                let dieLabels = LabelNormalization.restore(snap.configuration.labels)
                // Capture DNS server before the detached task so it can unregister on --rm reap.
                let dnsServerForTask = req.application.storage[SocktainerDNSServerKey.self]
                Task.detached {
                    // Await the authoritative exit code recorded by the start() background
                    // waiter once the init process exits. Using the store's continuation-based
                    // wait (rather than client.wait's timed grace-poll) means the die event
                    // always carries the real code, even under load — no `?? 0` fallback race.
                    let code = await ContainerExitCodeStore.shared.waitForCode(id: nativeId)
                    var attrs = dieLabels
                    attrs["exitCode"] = String(code)
                    let dieEvent = DockerEvent.simpleEvent(
                        id: eventId, type: "container", status: "die",
                        image: dieImage, name: dieName, labels: attrs
                    )
                    await broadcaster.broadcast(dieEvent)

                    // moby fires `destroy` right after `die` for `--rm` containers. Apple Container
                    // reaps them itself (no DELETE arrives), so emit it here. consumeAutoRemove both
                    // gates on the --rm flag and dedups against the foreground attach path, so a
                    // container attached in the foreground does not get a second destroy.
                    if await ContainerInfoCache.shared.consumeAutoRemove(id: nativeId) {
                        // Clean up DNS entry with ownership check (same pattern as ContainerDeleteRoute).
                        if let dnsServer = dnsServerForTask {
                            let cachedIP = await ContainerInfoCache.shared.get(id: nativeId)?.ip
                            let registered = dnsServer.listEntries()[SocktainerDNSServer.normalize(nativeId)]
                            if cachedIP == nil || registered == nil || registered == cachedIP {
                                dnsServer.unregister(hostname: nativeId)
                            }
                        }
                        await broadcaster.broadcast(
                            ContainerAttachRoute.makeAutoRemoveEvent(
                                id: eventId, image: dieImage, name: dieName, labels: dieLabels))
                        await ContainerInfoCache.shared.remove(id: nativeId)
                    }
                }
            }

            return .noContent
        }
    }
}
