import Vapor

func configure(_ app: Application) async throws {
    let containerClient = ClientContainerService()
    let imageClient = ClientImageService()
    let healthCheckClient = ClientHealthCheckService()

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
    try app.register(collection: ContainerAttachRoute())
    try app.register(collection: ContainerAttachWSRoute())
    try app.register(collection: ContainerChangesRoute())
    try app.register(collection: ContainerCreateRoute())
    try app.register(collection: ContainerDeleteRoute(client: containerClient))
    try app.register(collection: ContainerExportRoute())
    try app.register(collection: ContainerInspectRoute(client: containerClient))
    try app.register(collection: ContainerKillRoute())
    try app.register(collection: ContainerListRoute(client: containerClient))
    try app.register(collection: ContainerLogsRoute(client: containerClient))
    try app.register(collection: ContainerPauseRoute())
    try app.register(collection: ContainerPruneRoute())
    try app.register(collection: ContainerRenameRoute())
    try app.register(collection: ContainerResizeRoute())
    try app.register(collection: ContainerRestartRoute())
    try app.register(collection: ContainerStartRoute(client: containerClient))
    try app.register(collection: ContainerStatsRoute())
    try app.register(collection: ContainerStopRoute(client: containerClient))
    try app.register(collection: ContainerTopRoute())
    try app.register(collection: ContainerUnpauseRoute())
    try app.register(collection: ContainerUpdateRoute())
    try app.register(collection: ContainerWaitRoute())

    // /images
    try app.register(collection: ImageDeleteRoute(client: imageClient))
    try app.register(collection: ImageGetRoute())
    try app.register(collection: ImageHistoryRoute())
    try app.register(collection: ImageListRoute(client: imageClient))
    try app.register(collection: ImagePruneRoute())
    try app.register(collection: ImagePullRoute(client: imageClient))
    try app.register(collection: ImagePushRoute())
    try app.register(collection: ImageSearchRoute())
    try app.register(collection: ImageSummaryRoute())
    try app.register(collection: ImageTagRoute())
    try app.register(collection: ImagesGetRoute())
    try app.register(collection: ImagesLoadRoute())

    // /volumes
    try app.register(collection: VolumeCreateRoute())
    try app.register(collection: VolumeListRoute())
    try app.register(collection: VolumeNameRoute())
    try app.register(collection: VolumePruneRoute())

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
    try app.register(collection: NetworkCreateRoute())
    try app.register(collection: NetworkDisconnectRoute())
    try app.register(collection: NetworkInspectRoute())
    try app.register(collection: NetworkListRoute())
    try app.register(collection: NetworkPruneRoute())

    // --- build/distribution routes ---
    try app.register(collection: BuildPruneRoute())
    try app.register(collection: BuildRoute())
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
    try app.register(collection: AuthRoute())
    try app.register(collection: CommitRoute())
    try app.register(collection: SystemDFRoute())
    try app.register(collection: VersionRoute())

    // Initialize broadcaster
    let broadcaster = EventBroadcaster()
    app.storage[EventBroadcasterKey.self] = broadcaster

    let folderPath = ("\(NSHomeDirectory())/Library/Application Support/com.apple.container")
    let parentFolderURL = URL(fileURLWithPath: folderPath)

    let watcher = FolderWatcher(parentFolderURL: parentFolderURL, broadcaster: broadcaster)
    app.storage[FolderWatcherKey.self] = watcher

    // Await starting watching
    watcher.startWatching()

}
