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
    try app.register(collection: ContainerListRoute(client: containerClient))
    try app.register(collection: ContainerInspectRoute(client: containerClient))
    try app.register(collection: ContainerLogsRoute(client: containerClient))
    try app.register(collection: ContainerStartRoute(client: containerClient))
    try app.register(collection: ContainerStopRoute(client: containerClient))
    try app.register(collection: ContainerDeleteRoute(client: containerClient))

    // /images
    try app.register(collection: ImageListRoute(client: imageClient))
    try app.register(collection: ImageDeleteRoute(client: imageClient))
    try app.register(collection: ImagePullRoute(client: imageClient))

    // /volumes
    try app.register(collection: VolumeListRoute())

    // /swarm
    try app.register(collection: SwarmRoute())
    try app.register(collection: SwarmInitRoute())
    try app.register(collection: SwarmJoinRoute())
    try app.register(collection: SwarmLeaveRoute())
    try app.register(collection: SwarmUpdateRoute())
    try app.register(collection: SwarmUnlockKeyRoute())
    try app.register(collection: SwarmUnlockRoute())

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
