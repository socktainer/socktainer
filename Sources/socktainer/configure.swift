import ContainerAPIClient
import ContainerPersistence
import ContainerResource
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
    let metadataStorageURL =
        ProcessInfo.processInfo.environment[
            "SOCKTAINER_METADATA_DIRECTORY"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? appleContainerAppSupportUrl
    try await DockerContainerMetadataStore.shared.configure(
        storageDirectory: metadataStorageURL,
        enforceExclusiveAccess: true
    )
    let containerInstanceOwnerID = NetworkRelayManager.ownerID(seed: metadataStorageURL)
    app.storage[ContainerInstanceOwnerKey.self] = containerInstanceOwnerID

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

    let imageMutationCoordinator = ImageMutationCoordinator()
    let imageIdentityResolver = ImageIdentityResolver(
        systemConfig: systemConfig,
        appSupportURL: appleContainerAppSupportUrl,
        mutationCoordinator: imageMutationCoordinator
    )
    let imageLeaseReconciler = LiveContainerImageLeaseReconciler(
        mutationCoordinator: imageMutationCoordinator,
        identityResolver: imageIdentityResolver
    )
    await ContainerImageLeaseReconcilerRegistry.shared.configure(
        imageLeaseReconciler
    )
    let containerClient = ClientContainerService(
        imageReferenceResolver: imageIdentityResolver,
        imageLeaseReconciler: imageLeaseReconciler
    )
    let containerImageMetadataProvider = CanonicalContainerImageMetadataProvider(
        resolver: imageIdentityResolver
    )
    await RestartPolicyOverrideStore.shared.configure(storageDirectory: appleContainerAppSupportUrl)
    let imageClient = ClientImageService(
        containerSystemConfig: systemConfig,
        identityResolver: imageIdentityResolver,
        mutationCoordinator: imageMutationCoordinator
    )
    let relayManager = try NetworkRelayManager(
        appSupportURL: appleContainerAppSupportUrl,
        runtimeRoot: metadataStorageURL,
        containerSystemConfig: systemConfig,
        imageClient: imageClient,
        eventLoopGroup: app.eventLoopGroup
    )
    app.storage[NetworkRelayManagerKey.self] = relayManager
    let publishedPortManager = PublishedPortManager(
        eventLoopGroup: app.eventLoopGroup,
        logger: Logger(label: "socktainer.ports"),
        relayProvider: relayManager
    )
    app.storage[PublishedPortManagerKey.self] = publishedPortManager
    await PublishedPortManagerRegistry.shared.configure(publishedPortManager)
    app.lifecycle.use(PublishedPortManagerLifecycle(manager: publishedPortManager))
    let healthCheckClient = ClientHealthCheckService()
    let networkClient = ClientNetworkService()
    let volumeClient = ClientVolumeService()
    let registryClient = ClientRegistryService()
    let archiveClient = ClientArchiveService(appSupportPath: appleContainerAppSupportUrl)
    let builderClient = ClientBuilderService(
        appSupportURL: appleContainerAppSupportUrl,
        containerSystemConfig: systemConfig,
        imageResolver: LiveBuilderImageIdentityResolver(
            resolver: imageIdentityResolver
        ),
        imageClient: imageClient,
        imageMutationCoordinator: imageMutationCoordinator,
        imageLeaseReconciler: imageLeaseReconciler
    )

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
    try app.register(
        collection: ContainerCreateRoute(
            client: containerClient,
            systemConfig: systemConfig,
            identityResolver: imageIdentityResolver,
            appSupportURL: appleContainerAppSupportUrl
        )
    )
    try app.register(collection: ContainerDeleteRoute(client: containerClient))
    try app.register(collection: ContainerExportRoute(containerClient: containerClient, archiveClient: archiveClient))
    try app.register(
        collection: ContainerInspectRoute(
            client: containerClient,
            imageMetadataProvider: containerImageMetadataProvider
        )
    )
    try app.register(collection: ContainerKillRoute(client: containerClient))
    try app.register(
        collection: ContainerListRoute(
            client: containerClient,
            imageMetadataProvider: containerImageMetadataProvider
        )
    )
    try app.register(collection: ContainerLogsRoute(client: containerClient))
    try app.register(collection: ContainerPauseRoute())
    try app.register(collection: ContainerPruneRoute(client: containerClient))
    try app.register(collection: ContainerRenameRoute(client: containerClient))
    try app.register(collection: ContainerResizeRoute(client: containerClient))
    try app.register(collection: ContainerRestartRoute(client: containerClient))
    try app.register(collection: ContainerStartRoute(client: containerClient))
    try app.register(collection: ContainerStatsRoute(client: containerClient))
    try app.register(collection: ContainerStopRoute(client: containerClient))
    try app.register(collection: ContainerTopRoute())
    try app.register(collection: ContainerUnpauseRoute())
    try app.register(collection: ContainerUpdateRoute(client: containerClient))
    try app.register(collection: ContainerWaitRoute(client: containerClient))

    // /images
    try app.register(collection: ImageDeleteRoute(client: imageClient))
    try app.register(collection: ImageHistoryRoute(systemConfig: systemConfig, identityResolver: imageIdentityResolver))
    try app.register(collection: ImageListRoute(client: imageClient))
    try app.register(collection: ImagePruneRoute(client: imageClient))
    try app.register(collection: ImageCreateRoute(client: imageClient))
    try app.register(collection: ImagePushRoute(client: imageClient))
    try app.register(collection: ImageSearchRoute())
    try app.register(collection: ImageInspectRoute(systemConfig: systemConfig, identityResolver: imageIdentityResolver))
    try app.register(
        collection: ImageTagRoute(
            systemConfig: systemConfig,
            identityResolver: imageIdentityResolver,
            tagger: imageClient
        )
    )
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
    try app.register(
        collection: BuildRoute(
            client: containerClient,
            builderClient: builderClient,
            systemConfig: systemConfig,
            imageClient: imageClient,
            appleContainerAppSupportURL: appleContainerAppSupportUrl,
            imageMutationCoordinator: imageMutationCoordinator
        )
    )
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
    try app.register(
        collection: SystemDFRoute(
            imageClient: imageClient, containerClient: containerClient, volumeClient: volumeClient, builderClient: builderClient,
            diskUsageProvider: ContainerClientDiskUsageProvider(),
            imageLayerDiskUsageProvider: ClientImageLayerDiskUsageProvider(),
            imageInventoryProvider: imageClient,
            imageMetadataProvider: containerImageMetadataProvider
        ))
    try app.register(collection: VersionRoute())

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

    let dnsManager = NetworkDNSManager(
        appSupportURL: appleContainerAppSupportUrl,
        dnsPort: resolvedDNSPort,
        containerSystemConfig: systemConfig,
        imageClient: imageClient
    )
    app.storage[NetworkDNSManagerKey.self] = dnsManager

    // Healthcheck executor: runs `HEALTHCHECK` probes inside containers and
    // tracks status so `/containers/{id}/json` can return `.State.Health`.
    let healthCheckManager = HealthCheckManager(broadcaster: broadcaster)
    app.storage[HealthCheckManagerKey.self] = healthCheckManager
    let recoveryScope =
        ProcessInfo.processInfo.environment["SOCKTAINER_CONTAINER_RECOVERY_SCOPE"]
        ?? "all"
    guard recoveryScope == "all" || recoveryScope == "metadata" else {
        throw Abort(
            .internalServerError,
            reason: "SOCKTAINER_CONTAINER_RECOVERY_SCOPE must be 'all' or 'metadata'"
        )
    }
    let recoveredLifecycleMonitor = RecoveredContainerLifecycleMonitor(
        client: containerClient,
        portManager: publishedPortManager,
        dnsServer: dnsServer,
        healthManager: healthCheckManager,
        logger: app.logger,
        requiredOwnerID: recoveryScope == "metadata" ? containerInstanceOwnerID : nil
    )
    if recoveryScope == "metadata" {
        app.logger.notice(
            "[startup] container recovery is scoped to this metadata registry"
        )
    }
    app.lifecycle.use(
        RecoveredContainerLifecycleHandler(monitor: recoveredLifecycleMonitor)
    )

    // Seed recovery when Apple is available immediately. The monitor is started
    // unconditionally and owns the same idempotent recovery path for containers
    // first discovered after a transient Apple service outage.
    let resumeClient = ContainerClient()
    var recoveredContainers: [ContainerSnapshot] = []
    if let runningContainers = try? await resumeClient.list() {
        recoveredContainers = runningContainers.filter {
            !ClientContainerService.isInfrastructureSidecar($0)
        }
        try? await DockerContainerMetadataStore.shared.reconcile(
            existingNativeIDs: Set(runningContainers.map(\.id))
        )
    }
    await recoveredLifecycleMonitor.start(containers: recoveredContainers)

    // Sidecar adoption and network reaping (in that order — a network whose only
    // member was its sidecar must appear empty to the reaper) are best-effort
    // housekeeping over XPC calls that hang indefinitely when the runtime is
    // wedged (apple/container#1884). Time-box them: a daemon that skips
    // housekeeping still serves clients, one that never binds its socket serves
    // nothing. Network reaping context: Apple Container's vmnet state degrades
    // as orphaned networks accumulate and eventually breaks container-to-container
    // routing (EHOSTUNREACH).
    if ProcessInfo.processInfo.environment["SOCKTAINER_SKIP_STARTUP_HOUSEKEEPING"] == "1" {
        app.logger.warning("[startup] housekeeping explicitly disabled for an isolated acceptance daemon")
    } else {
        let housekeepingLogger = app.logger
        let housekeepingFinished = await StartupHousekeeping.runBounded(timeout: .seconds(30)) {
            await dnsManager.adoptOrRemoveSidecarsFromPreviousRun()
            await relayManager.adoptOrRemoveSidecarsFromPreviousRun()
            await OrphanedNetworkReaper.reap(networkClient: ClientNetworkService(), logger: housekeepingLogger)
        }
        if !housekeepingFinished {
            app.logger.warning(
                "[startup] infrastructure-sidecar adoption / orphaned-network reaping did not finish within 30s — continuing startup without it. The container runtime may be unhealthy (see apple/container#1884)."
            )
        }
    }

}
