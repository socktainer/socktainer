import ContainerPersistence
import ContainerResource
import ContainerizationError
import Vapor

struct AppleContainerAppSupportUrlKey: StorageKey {
    typealias Value = URL
}

func configure(_ app: Application) async throws {
    guard #available(macOS 26.0, *) else {
        throw Abort(.internalServerError, reason: "Socktainer requires macOS 26 or newer")
    }

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

    let healthCheckClient = ClientHealthCheckService()
    let networkClient = ClientNetworkService()
    let volumeClient = ClientVolumeService()
    let registryClient = ClientRegistryService()
    let engineController = LinuxPodEngineController(
        artifact: try EngineGuestImageArtifact.locate(),
        eventLoopGroup: app.eventLoopGroup
    )
    let engine = PersistentEngine(controller: engineController)
    _ = try await engine.readyConnection()
    let bindCacheController = BindCacheInvalidationController(
        source: FSEventsBindHostEventSource(root: FileManager.default.homeDirectoryForCurrentUser),
        sink: GuestConnectionBindCacheSink(engine: engine)
    )
    let bindCacheBridge = GuestBindCacheBridge(
        events: PersistentEngineBindCacheEventConnector(engine: engine),
        controller: bindCacheController
    )
    try await bindCacheBridge.start()
    app.lifecycle.use(GuestBindCacheEngineLifecycle(bridge: bindCacheBridge, engine: engine))
    let directPortForwarder = DirectTCPPortForwarder(
        eventLoopGroup: app.eventLoopGroup,
        logger: Logger(label: "socktainer.direct-ports")
    )
    app.lifecycle.use(DirectTCPPortForwarderLifecycle(forwarder: directPortForwarder))
    let runtime = GuestRuntime(
        engine: engine,
        portPublisher: GuestPortPublicationManager(forwarder: directPortForwarder)
    )
    try await runtime.startEventMonitor()
    app.lifecycle.use(GuestRuntimeLifecycle(runtime: runtime))

    // Create and install regex routing middleware with logging
    let regexRouter = app.regexRouter(with: app.logger)
    app.setRegexRouter(regexRouter)
    regexRouter.installMiddleware(on: app)

    // /_ping
    try app.register(collection: HealthCheckPingRoute(client: healthCheckClient))

    // /events
    try app.register(collection: EventsRoute(client: healthCheckClient))

    try app.register(collection: DockerRuntimeRoutes(backend: runtime))

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

    // Build routes are intentionally absent until the guest runtime owns
    // BuildKit. The former builder service created another Apple VM.
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
    try app.register(collection: VersionRoute())

    // Initialize broadcaster
    let broadcaster = EventBroadcaster()
    app.storage[EventBroadcasterKey.self] = broadcaster
    app.storage[AppleContainerAppSupportUrlKey.self] = appleContainerAppSupportUrl

}
