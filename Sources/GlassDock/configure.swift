import ContainerResource
import Vapor

func configure(
    _ app: Application,
    cpuCount: Int = RuntimeMachineConfiguration.defaultCPUCount,
    memoryBytes: UInt64 = RuntimeMachineConfiguration.defaultMemoryBytes
) async throws {
    guard #available(macOS 26.0, *) else {
        throw Abort(.internalServerError, reason: "Glass Dock requires macOS 26 or newer")
    }

    // Docker container-create payloads (large env / config — e.g. Supabase's
    // edge-runtime + storage-api) exceed Vapor's 16 KB default collected-body
    // cap, yielding 413 "Payload Too Large". Raise it well above any real request.
    app.routes.defaultMaxBodySize = "64mb"

    // Make error responses Docker-compatible (`{"message": ...}`) so SDKs like
    // docker-py don't crash on their `response.json()['message']` lookup. Installed
    // outermost so it wraps all routing/error handling. See DockerErrorMiddleware.
    app.middleware.use(DockerErrorMiddleware(), at: .beginning)

    let volumeClient = RuntimeVolumeService()
    let broadcaster = EventBroadcaster()
    app.storage[EventBroadcasterKey.self] = broadcaster
    let engineStateDirectory = GlassDockDirectories.engineStateDirectory
    let engineDataDisk = engineStateDirectory.appendingPathComponent("data.ext4")
    let machineArtifacts = try RuntimeMachineArtifacts.locate()
    let machine = RuntimeMachine(
        configuration: try RuntimeMachineConfiguration(
            helperExecutable: machineArtifacts.helper,
            stateDirectory: engineStateDirectory,
            kernel: machineArtifacts.kernel,
            rootDisk: machineArtifacts.rootDisk,
            dataDisk: engineDataDisk,
            bindSource: GlassDockDirectories.hostHome,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes
        )
    )
    let engine = PersistentEngine(machine: machine)
    app.lifecycle.use(PersistentEngineLifecycle(engine: engine))
    let portPublisher = GuestPortPublicationManager(
        controller: GVProxyPublishedPortController {
            try await machine.start()
        }
    )
    app.lifecycle.use(GuestPortPublicationLifecycle(manager: portPublisher))
    let runtime = GuestRuntime(
        engine: engine,
        portPublisher: portPublisher,
        broadcaster: broadcaster
    )
    await volumeClient.setReferenceValidator { id in
        (try? await runtime.inspectContainer(id: id)) != nil
    }
    app.lifecycle.use(GuestRuntimeLifecycle(runtime: runtime))
    let readiness = RuntimeReadiness {
        _ = try await engine.readyConnection()
        try await runtime.startEventMonitor()
    }
    app.middleware.use(RuntimeReadinessMiddleware(readiness: readiness))
    // Shutdown runs lifecycle handlers in reverse registration order. Cancel
    // unfinished initialization before the runtime tears down its connections.
    app.lifecycle.use(RuntimeReadinessLifecycle(readiness: readiness))

    // Create and install regex routing middleware with logging
    let regexRouter = app.regexRouter(with: app.logger)
    app.setRegexRouter(regexRouter)
    regexRouter.installMiddleware(on: app)

    // /_ping
    try app.register(collection: HealthCheckPingRoute())

    // /events
    try app.register(collection: EventsRoute())

    try app.register(collection: DockerRuntimeRoutes(backend: runtime, volumeClient: volumeClient))
    try app.register(collection: AuthRoute())
    try app.register(collection: ExplicitUnsupportedDockerRoutes())

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

    // Build routes are intentionally absent until the guest runtime owns
    // BuildKit. The former builder service created another Apple VM.
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
    try app.register(collection: VersionRoute())

}
