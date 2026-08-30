import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import Vapor

struct AppleContainerAppSupportUrlKey: StorageKey {
    typealias Value = URL
}

func configure(_ app: Application) async throws {

    // Docker container-create payloads (large env / config — e.g. Supabase's
    // edge-runtime + storage-api) exceed Vapor's 16 KB default collected-body
    // cap, yielding 413 "Payload Too Large". Raise it well above any real request.
    app.routes.defaultMaxBodySize = "64mb"

    // Make error responses Docker-compatible (`{"message": ...}`) so SDKs like
    // docker-py don't crash on their `response.json()['message']` lookup. Installed
    // outermost so it wraps all routing/error handling. See DockerErrorMiddleware.
    app.middleware.use(DockerErrorMiddleware(), at: .beginning)

    // Define app support path early since it's needed by multiple services
    let folderPath = ("\(NSHomeDirectory())/Library/Application Support/com.apple.container")
    let appleContainerAppSupportUrl = URL(fileURLWithPath: folderPath)

    let systemConfig: ContainerSystemConfig
    do {
        systemConfig = try await ConfigurationLoader.load()
    } catch let err as ContainerizationError {
        app.logger.error("System config is malformed — falling back to defaults. Fix your config.toml: \(err)")
        systemConfig = ContainerSystemConfig()
    } catch {
        app.logger.warning("Failed to load system config at startup, using defaults: \(error)")
        systemConfig = ContainerSystemConfig()
    }

    let containerClient = ClientContainerService()
    await RestartPolicyOverrideStore.shared.configure(storageDirectory: appleContainerAppSupportUrl)
    let imageClient = ClientImageService(containerSystemConfig: systemConfig)
    let healthCheckClient = ClientHealthCheckService()
    let networkClient = ClientNetworkService()
    let volumeClient = ClientVolumeService()
    let registryClient = ClientRegistryService()
    let archiveClient = ClientArchiveService(appSupportPath: appleContainerAppSupportUrl)
    let builderClient = ClientBuilderService(appSupportURL: appleContainerAppSupportUrl, containerSystemConfig: systemConfig)

    // Create and install regex routing middleware with logging
    let regexRouter = app.regexRouter(with: app.logger)
    app.setRegexRouter(regexRouter)
    regexRouter.installMiddleware(on: app)

    // /_ping
    try app.register(collection: HealthCheckPingRoute(client: healthCheckClient))

    // /info
    try app.register(collection: InfoRoute(containerClient: containerClient, imageClient: imageClient))

    // /events
    try app.register(collection: EventsRoute(client: healthCheckClient))

    // exec
    try app.register(collection: ExecRoute(client: containerClient))

    // /containers
    try app.register(collection: ContainerArchiveRoute(containerClient: containerClient, archiveClient: archiveClient))
    try app.register(collection: ContainerAttachRoute(client: containerClient))
    try app.register(collection: ContainerAttachWSRoute(client: containerClient))
    try app.register(collection: ContainerChangesRoute())
    try app.register(collection: ContainerCreateRoute(client: containerClient, systemConfig: systemConfig))
    try app.register(collection: ContainerDeleteRoute(client: containerClient))
    try app.register(collection: ContainerExportRoute(containerClient: containerClient, archiveClient: archiveClient))
    try app.register(collection: ContainerInspectRoute(client: containerClient))
    try app.register(collection: ContainerKillRoute(client: containerClient))
    try app.register(collection: ContainerListRoute(client: containerClient))
    try app.register(collection: ContainerLogsRoute(client: containerClient))
    try app.register(collection: ContainerPauseRoute())
    try app.register(collection: ContainerPruneRoute(client: containerClient))
    try app.register(collection: ContainerRenameRoute())
    try app.register(collection: ContainerResizeRoute(client: containerClient))
    try app.register(collection: ContainerRestartRoute(client: containerClient))
    try app.register(collection: ContainerStartRoute(client: containerClient))
    try app.register(collection: ContainerStatsRoute())
    try app.register(collection: ContainerStopRoute(client: containerClient))
    try app.register(collection: ContainerTopRoute())
    try app.register(collection: ContainerUnpauseRoute())
    try app.register(collection: ContainerUpdateRoute(client: containerClient))
    try app.register(collection: ContainerWaitRoute(client: containerClient))

    // /images
    let manifestClient = ClientManifestService(appSupportURL: appleContainerAppSupportUrl, containerSystemConfig: systemConfig)
    try app.register(collection: ImageDeleteRoute(client: imageClient))
    try app.register(collection: ImageHistoryRoute(systemConfig: systemConfig))
    try app.register(collection: ImageListRoute(client: imageClient))
    try app.register(collection: ImagePruneRoute(client: imageClient))
    try app.register(collection: ImageCreateRoute(client: imageClient))
    try app.register(collection: ImagePushRoute(client: imageClient, manifestClient: manifestClient))
    try app.register(collection: ImageSearchRoute())
    try app.register(collection: ImageInspectRoute(systemConfig: systemConfig))
    try app.register(collection: ImageTagRoute(systemConfig: systemConfig))
    try app.register(collection: ImagesGetRoute(client: imageClient))
    try app.register(collection: ImagesLoadRoute(client: imageClient))

    // /volumes
    try app.register(collection: VolumeCreateRoute(client: volumeClient))
    try app.register(collection: VolumeDeleteRoute(client: volumeClient))
    try app.register(collection: VolumeInspectRoute(client: volumeClient))
    try app.register(collection: VolumeListRoute(client: volumeClient))
    try app.register(collection: VolumePruneRoute(client: volumeClient))

    // /swarm
    try app.register(collection: SwarmInitRoute())
    try app.register(collection: SwarmJoinRoute())
    try app.register(collection: SwarmLeaveRoute())
    try app.register(collection: SwarmRoute())
    try app.register(collection: SwarmUnlockKeyRoute())
    try app.register(collection: SwarmUnlockRoute())
    try app.register(collection: SwarmUpdateRoute())

    // --- network routes ---
    try app.register(collection: NetworkConnectRoute())
    try app.register(collection: NetworkCreateRoute(client: networkClient))
    try app.register(collection: NetworkDisconnectRoute())
    try app.register(collection: NetworkInspectRoute(client: networkClient))
    try app.register(collection: NetworkListRoute())
    try app.register(collection: NetworkPruneRoute(client: networkClient))
    try app.register(collection: NetworkDeleteRoute(client: networkClient))

    // --- build/distribution routes ---
    try app.register(collection: BuildPruneRoute(builderClient: builderClient))
    try app.register(collection: BuildRoute(client: containerClient, builderClient: builderClient, systemConfig: systemConfig, manifestClient: manifestClient))
    try app.register(collection: DistributionJsonRoute(systemConfig: systemConfig))

    // --- plugin routes ---
    try app.register(collection: PluginsCreateRoute())
    try app.register(collection: PluginsNameDisableRoute())
    try app.register(collection: PluginsNameEnableRoute())
    try app.register(collection: PluginsNameJsonRoute())
    try app.register(collection: PluginsNamePushRoute())
    try app.register(collection: PluginsNameRoute())
    try app.register(collection: PluginsNameSetRoute())
    try app.register(collection: PluginsNameUpgradeRoute())
    try app.register(collection: PluginsPrivilegesRoute())
    try app.register(collection: PluginsPullRoute())
    try app.register(collection: PluginsRoute())

    // --- swarm node routes ---
    try app.register(collection: NodesIdRoute())
    try app.register(collection: NodesIdUpdateRoute())
    try app.register(collection: NodesRoute())

    // --- swarm service routes ---
    try app.register(collection: ServicesCreateRoute())
    try app.register(collection: ServicesIdLogsRoute())
    try app.register(collection: ServicesIdRoute())
    try app.register(collection: ServicesIdUpdateRoute())
    try app.register(collection: ServicesRoute())

    // --- swarm task routes ---
    try app.register(collection: TasksIdLogsRoute())
    try app.register(collection: TasksIdRoute())
    try app.register(collection: TasksRoute())

    // --- Swarm secret routes ---
    try app.register(collection: SecretsCreateRoute())
    try app.register(collection: SecretsIdRoute())
    try app.register(collection: SecretsIdUpdateRoute())
    try app.register(collection: SecretsRoute())

    // --- swarm config routes ---
    try app.register(collection: ConfigsCreateRoute())
    try app.register(collection: ConfigsIdRoute())
    try app.register(collection: ConfigsIdUpdateRoute())
    try app.register(collection: ConfigsRoute())

    // --- session route ---
    try app.register(collection: SessionRoute())

    // --- miscellaneous ---
    try app.register(collection: AuthRoute(client: registryClient))
    try app.register(collection: CommitRoute())
    let systemDFRoute = SystemDFRoute(
        imageClient: imageClient, containerClient: containerClient, volumeClient: volumeClient, builderClient: builderClient,
        diskUsageProvider: ContainerClientDiskUsageProvider(),
        imageLayerDiskUsageProvider: ClientImageLayerDiskUsageProvider()
    )
    try app.register(collection: systemDFRoute)
    try app.register(collection: VersionRoute())

    // --- Podman libpod routes ---
    try app.register(collection: LibpodPingRoute(client: healthCheckClient))
    try app.register(collection: LibpodVersionRoute())
    try app.register(collection: LibpodInfoRoute(containerClient: containerClient, imageClient: imageClient))
    try app.register(collection: LibpodContainerListRoute(client: containerClient))
    try app.register(collection: LibpodContainerCreateRoute(client: containerClient, systemConfig: systemConfig))
    try app.register(collection: LibpodContainerStartRoute(client: containerClient))
    try app.register(collection: LibpodContainerStopRoute(client: containerClient))
    try app.register(collection: LibpodContainerKillRoute(client: containerClient))
    try app.register(collection: LibpodContainerAttachRoute(client: containerClient))
    try app.register(collection: LibpodContainerWaitRoute(client: containerClient))
    try app.register(collection: LibpodContainerInspectRoute(client: containerClient))
    try app.register(collection: LibpodContainerDeleteRoute(client: containerClient))
    try app.register(collection: LibpodImageListRoute(client: imageClient))
    try app.register(collection: LibpodImagePullRoute(client: imageClient))
    try app.register(collection: LibpodImageDeleteRoute(client: imageClient))
    try app.register(collection: LibpodImageInspectRoute(systemConfig: systemConfig))
    try app.register(collection: LibpodImageTagRoute(systemConfig: systemConfig))
    try app.register(collection: LibpodBuildRoute(client: containerClient, builderClient: builderClient, systemConfig: systemConfig, manifestClient: manifestClient))
    try app.register(collection: LibpodContainerLogsRoute(client: containerClient))
    try app.register(collection: LibpodContainerTopRoute())
    try app.register(collection: LibpodContainerRenameRoute())
    try app.register(collection: LibpodContainerRestartRoute(client: containerClient))
    try app.register(collection: LibpodExecCreateRoute(client: containerClient))
    try app.register(collection: LibpodExecStartRoute(client: containerClient))
    try app.register(collection: LibpodExecInspectRoute(client: containerClient))
    try app.register(collection: LibpodVolumeListRoute(dockerRoute: VolumeListRoute(client: volumeClient)))
    try app.register(collection: LibpodVolumeCreateRoute(dockerRoute: VolumeCreateRoute(client: volumeClient)))
    try app.register(collection: LibpodVolumeDeleteRoute(dockerRoute: VolumeDeleteRoute(client: volumeClient)))
    try app.register(collection: LibpodVolumeInspectRoute(dockerRoute: VolumeInspectRoute(client: volumeClient)))
    try app.register(collection: LibpodNetworkListRoute())
    try app.register(collection: LibpodNetworkCreateRoute(dockerRoute: NetworkCreateRoute(client: networkClient)))
    try app.register(collection: LibpodNetworkDeleteRoute(dockerRoute: NetworkDeleteRoute(client: networkClient)))
    try app.register(collection: LibpodNetworkInspectRoute(client: networkClient))
    try app.register(
        collection: LibpodSystemDFRoute(dockerRoute: systemDFRoute))
    try app.register(collection: LibpodAuthRoute(client: registryClient))

    // --- Podman libpod routes: stats/pause/prune/cp/push/save/load/events gaps ---
    try app.register(collection: LibpodContainerStatsRoute())
    try app.register(collection: LibpodContainerPauseRoute())
    try app.register(collection: LibpodContainerUnpauseRoute())
    try app.register(collection: LibpodContainerChangesRoute())
    try app.register(collection: LibpodContainerPruneRoute(dockerRoute: ContainerPruneRoute(client: containerClient)))
    try app.register(collection: LibpodContainerUpdateRoute(client: containerClient))
    try app.register(collection: LibpodContainerExportRoute(containerClient: containerClient, archiveClient: archiveClient))
    try app.register(collection: LibpodContainerArchiveRoute(containerClient: containerClient, archiveClient: archiveClient))
    try app.register(collection: LibpodImagePushRoute(client: imageClient, manifestClient: manifestClient))
    try app.register(collection: LibpodImagePruneRoute(dockerRoute: ImagePruneRoute(client: imageClient)))
    try app.register(collection: LibpodImagesGetRoute(client: imageClient))
    try app.register(collection: LibpodImagesLoadRoute(client: imageClient))
    try app.register(collection: LibpodVolumePruneRoute(dockerRoute: VolumePruneRoute(client: volumeClient)))
    try app.register(collection: LibpodNetworkPruneRoute(client: networkClient))
    try app.register(collection: LibpodNetworkConnectRoute())
    try app.register(collection: LibpodNetworkDisconnectRoute())
    try app.register(collection: LibpodEventsRoute(client: healthCheckClient))
    try app.register(collection: LibpodImageImportRoute(client: imageClient))
    try app.register(collection: LibpodImageSearchRoute(dockerRoute: ImageSearchRoute()))
    try app.register(collection: LibpodImageHistoryRoute(systemConfig: systemConfig))
    try app.register(collection: LibpodCommitRoute())
    try app.register(collection: LibpodContainerExistsRoute(client: containerClient))
    try app.register(collection: LibpodImageExistsRoute(systemConfig: systemConfig))
    try app.register(collection: LibpodVolumeExistsRoute(client: volumeClient))
    try app.register(collection: LibpodNetworkExistsRoute(client: networkClient))

    try app.register(collection: LibpodManifestCreateRoute(client: manifestClient))
    try app.register(collection: LibpodManifestInspectRoute(client: manifestClient))
    try app.register(collection: LibpodManifestExistsRoute(client: manifestClient))
    try app.register(collection: LibpodManifestModifyRoute(client: manifestClient))
    try app.register(collection: LibpodManifestDeleteRoute(client: manifestClient))
    try app.register(collection: LibpodManifestPushRoute(manifestClient: manifestClient, imageClient: imageClient))

    // Initialize broadcaster
    let broadcaster = EventBroadcaster()
    app.storage[EventBroadcasterKey.self] = broadcaster
    app.storage[AppleContainerAppSupportUrlKey.self] = appleContainerAppSupportUrl

    // Initialize inter-container DNS infrastructure.
    // Port is read from SOCKTAINER_DNS_PORT (default 2054). If the preferred port
    // is taken, Socktainer auto-increments until a free port is found.
    let preferredDNSPort =
        ProcessInfo.processInfo.environment["SOCKTAINER_DNS_PORT"]
        .flatMap(Int.init) ?? 2054
    let dnsServer = SocktainerDNSServer()
    guard let resolvedDNSPort = dnsServer.start(preferredPort: preferredDNSPort) else {
        app.logger.error("Could not bind DNS server on any port near \(preferredDNSPort) — inter-container DNS disabled")
        return
    }
    app.logger.notice("DNS server listening on port \(resolvedDNSPort)")
    app.storage[SocktainerDNSServerKey.self] = dnsServer

    let dnsManager = NetworkDNSManager(appSupportURL: appleContainerAppSupportUrl, dnsPort: resolvedDNSPort, containerSystemConfig: systemConfig)
    app.storage[NetworkDNSManagerKey.self] = dnsManager

    // Healthcheck executor: runs `HEALTHCHECK` probes inside containers and
    // tracks status so `/containers/{id}/json` can return `.State.Health`.
    let healthCheckManager = HealthCheckManager(broadcaster: broadcaster)
    app.storage[HealthCheckManagerKey.self] = healthCheckManager

    // Resume healthcheck loops and DNS registrations for any containers that were
    // running when Socktainer last stopped. SocktainerDNSServer is in-memory so
    // entries are lost on restart; without re-registration containers that are
    // restarted (not re-created) via docker start cannot be resolved by peers.
    let resumeClient = ContainerClient()
    if let runningContainers = try? await resumeClient.list() {
        for container in runningContainers where container.status == .running {
            // Skip DNS-sidecar containers — they are internal infrastructure.
            guard !ClientContainerService.isDNSSidecar(container)
            else { continue }

            ContainerStartRoute.registerDNSAliasesOnResume(container: container, dnsServer: dnsServer, logger: app.logger)

            // Resume healthcheck loop if the container has one.
            guard let json = container.configuration.labels[HealthCheckManager.healthcheckLabel],
                let config = try? JSONDecoder().decode(HealthcheckConfig.self, from: Data(json.utf8)),
                HealthCheckManager.parseTest(config.Test) != nil  // skip NONE / disabled checks
            else { continue }
            await healthCheckManager.start(containerId: container.id, config: config)
            app.logger.info("Resumed healthcheck for \(container.id)")
        }
    }

    // Sidecar adoption and network reaping (in that order — a network whose only
    // member was its sidecar must appear empty to the reaper) are best-effort
    // housekeeping over XPC calls that hang indefinitely when the runtime is
    // wedged (apple/container#1884). Time-box them: a daemon that skips
    // housekeeping still serves clients, one that never binds its socket serves
    // nothing. Network reaping context: Apple Container's vmnet state degrades
    // as orphaned networks accumulate and eventually breaks container-to-container
    // routing (EHOSTUNREACH).
    let housekeepingLogger = app.logger
    let housekeepingFinished = await StartupHousekeeping.runBounded(timeout: .seconds(30)) {
        await dnsManager.adoptOrRemoveSidecarsFromPreviousRun()
        await OrphanedNetworkReaper.reap(networkClient: ClientNetworkService(), logger: housekeepingLogger)
    }
    if !housekeepingFinished {
        app.logger.warning(
            "[startup] DNS-sidecar adoption / orphaned-network reaping did not finish within 30s — continuing startup without it. The container runtime may be unhealthy (see apple/container#1884)."
        )
    }

}
