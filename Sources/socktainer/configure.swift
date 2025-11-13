import Vapor

struct AppleContainerAppSupportUrlKey: StorageKey {
    typealias Value = URL
}

func configure(_ app: Application) async throws {

    let containerClient = ClientContainerService()
    let imageClient = ClientImageService()
    let healthCheckClient = ClientHealthCheckService()
    let networkClient = ClientNetworkService()
    let volumeClinet = ClientVolumeService()
    let registryClient = ClientRegistryService()

    // Create and install regex routing middleware with logging
    let regexRouter = app.regexRouter(with: app.logger)
    app.setRegexRouter(regexRouter)
    regexRouter.installMiddleware(on: app)

    // /_ping
    try app.register(collection: HealthCheckPingRoute(client: healthCheckClient))

    // /info
    try app.register(collection: InfoRoute())

    // /events
    try app.register(collection: EventsRoute(client: healthCheckClient))

    // exec
    try app.register(collection: ExecRoute(client: containerClient))

    // /containers
    try app.register(collection: ContainerArchiveRoute())
    try app.register(collection: ContainerAttachRoute(client: containerClient))
    try app.register(collection: ContainerAttachWSRoute())
    try app.register(collection: ContainerChangesRoute())
    try app.register(collection: ContainerCreateRoute(client: containerClient))
    try app.register(collection: ContainerDeleteRoute(client: containerClient))
    try app.register(collection: ContainerExportRoute())
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
    try app.register(collection: ContainerUpdateRoute())
    try app.register(collection: ContainerWaitRoute(client: containerClient))

    // /images
    try app.register(collection: ImageDeleteRoute(client: imageClient))
    try app.register(collection: ImageHistoryRoute())
    try app.register(collection: ImageListRoute(client: imageClient))
    try app.register(collection: ImagePruneRoute(client: imageClient))
    try app.register(collection: ImageCreateRoute(client: imageClient))
    try app.register(collection: ImagePushRoute(client: imageClient))
    try app.register(collection: ImageSearchRoute())
    try app.register(collection: ImageInspectRoute(client: imageClient))
    try app.register(collection: ImageTagRoute())
    try app.register(collection: ImagesGetRoute(client: imageClient))
    try app.register(collection: ImagesLoadRoute(client: imageClient))

    // /volumes
    try app.register(collection: VolumeCreateRoute(client: volumeClinet))
    try app.register(collection: VolumeDeleteRoute(client: volumeClinet))
    try app.register(collection: VolumeInspectRoute(client: volumeClinet))
    try app.register(collection: VolumeListRoute(client: volumeClinet))
    try app.register(collection: VolumePruneRoute(client: volumeClinet))

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
    try app.register(collection: NetworkDeletetRoute(client: networkClient))

    // --- build/distribution routes ---
    try app.register(collection: BuildPruneRoute())
    try app.register(collection: BuildRoute(client: containerClient))
    try app.register(collection: DistributionJsonRoute())

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
    try app.register(collection: SystemDFRoute())
    try app.register(collection: VersionRoute())

    // Initialize broadcaster
    let broadcaster = EventBroadcaster()
    app.storage[EventBroadcasterKey.self] = broadcaster

    let folderPath = ("\(NSHomeDirectory())/Library/Application Support/com.apple.container")
    let appleContainerAppSupportUrl = URL(fileURLWithPath: folderPath)

    app.storage[AppleContainerAppSupportUrlKey.self] = appleContainerAppSupportUrl

    let watcher = FolderWatcher(parentFolderURL: appleContainerAppSupportUrl, broadcaster: broadcaster)
    app.storage[FolderWatcherKey.self] = watcher

    // Await starting watching
    watcher.startWatching()

}
