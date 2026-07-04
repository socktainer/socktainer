import ContainerAPIClient
import ContainerNetworkClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Vapor

struct ContainerCreateRoute: RouteCollection {
    let client: ClientContainerProtocol
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/create", use: ContainerCreateRoute.handler(client: client, systemConfig: systemConfig))
    }

}

struct ContainerCreateQuery: Content {
    var name: String?
    var platform: String?
}
struct CreateContainerRequest: Content {
    let Image: String
    let Hostname: String?
    let Domainname: String?
    let User: String?
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let PortSpecs: [String]?
    let Tty: Bool?
    let OpenStdin: Bool?
    let StdinOnce: Bool?
    let Env: [String]?
    let Cmd: [String]?
    let Healthcheck: HealthcheckConfig?
    let ArgsEscaped: Bool?
    let Entrypoint: [String]?
    let Volumes: [String: EmptyObject]?
    let WorkingDir: String?
    let MacAddress: String?
    let OnBuild: [String]?
    let NetworkDisabled: Bool?
    let ExposedPorts: [String: EmptyObject]?
    let StopSignal: String?
    let StopTimeout: Int?
    let HostConfig: HostConfig?
    let Labels: [String: String]?
    let Shell: [String]?
    let NetworkingConfig: ContainerNetworkSettings?
}

extension ContainerCreateRoute {
    static func handler(client: ClientContainerProtocol, systemConfig: ContainerSystemConfig) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(ContainerCreateQuery.self)

            let containerName = query.name

            // use platform "" if not provided
            let containerPlatform = (query.platform?.isEmpty == false) ? query.platform! : "linux/\(Arch.hostArchitecture().rawValue)"

            // `collect()` with no max silently caps at Vapor's 1<<14 (16 KB)
            // default — `defaultMaxBodySize` is only consulted by Vapor's
            // registered-route collection, which the RegexRouter bypasses. A
            // container-create payload (e.g. Supabase's edge-runtime / storage
            // services carry large env + config) exceeds 16 KB and would 413
            // "Payload Too Large". Honor the configured cap explicitly.
            guard let bodyData = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get(),
                let data = bodyData.getData(at: 0, length: bodyData.readableBytes), !data.isEmpty
            else {
                // No body (e.g. an empty POST) — return 400 rather than trapping
                // on a force-unwrap.
                throw Abort(.badRequest, reason: "Request body is required")
            }
            let body: CreateContainerRequest
            do {
                body = try JSONDecoder().decode(CreateContainerRequest.self, from: data)
            } catch {
                // Malformed JSON is bad client input, not a server fault — 400, not 500.
                throw Abort(.badRequest, reason: "Invalid JSON request body")
            }

            req.logger.info("Creating container for image: \(body.Image)")

            let requestedStopSignal = body.StopSignal.flatMap { $0.isEmpty ? nil : $0 }
            if let requestedStopSignal, !DockerSignal.isValid(requestedStopSignal) {
                throw Abort(.badRequest, reason: "invalid signal: \(requestedStopSignal)")
            }

            if let requestedShmSize = body.HostConfig?.ShmSize, requestedShmSize < 0 {
                throw Abort(.badRequest, reason: "SHM size can not be less than 0")
            }

            let normalizedCapabilities: (capAdd: [String], capDrop: [String])
            do {
                normalizedCapabilities = try Parser.capabilities(
                    capAdd: body.HostConfig?.CapAdd ?? [],
                    capDrop: body.HostConfig?.CapDrop ?? [])
            } catch {
                throw Abort(.badRequest, reason: "invalid capability: \(error)")
            }

            if let cpuValidationError = ContainerCreateRoute.validateCpuLimits(hostConfig: body.HostConfig) {
                throw Abort(.badRequest, reason: cpuValidationError)
            }

            let rawId = Utility.createContainerID(name: containerName)
            let id = ContainerNameUtility.sanitize(rawId)
            try Utility.validEntityName(id)

            // Validate the requested platform only if provided
            var requestedPlatform = try Platform(from: containerPlatform)

            // Check if image exists locally
            do {
                _ = try await ClientImage.get(reference: body.Image, containerSystemConfig: systemConfig)
            } catch {
                throw Abort(.notFound, reason: "No such image: \(body.Image)")
            }

            // Fetch the image; on arm64 hosts fall back to amd64 (Rosetta) when no arm64
            // variant is available. Two cases handled:
            //   1. Fetch fails (image not cached, pull returns "does not support required platforms")
            //   2. Fetch succeeds but image is cached as amd64 — config(for: arm64) returns nil
            // containerConfiguration.rosetta is set below when requestedPlatform becomes amd64.
            var img: ClientImage
            do {
                img = try await ClientImage.fetch(
                    reference: body.Image,
                    platform: requestedPlatform,
                    containerSystemConfig: systemConfig
                )
                // Case 2: image exists locally but may have been pulled as amd64
                if requestedPlatform.architecture == "arm64",
                    (try? await img.config(for: requestedPlatform)) == nil
                {
                    throw ContainerizationError(.notFound, message: "no arm64 content")
                }
            } catch let fetchError
                where requestedPlatform.architecture == "arm64"
                && {
                    let msg = String(describing: fetchError)
                    return msg.contains("does not support required platforms") || msg.contains("no arm64 content")
                }()
            {
                let amd64 = Platform(arch: "amd64", os: requestedPlatform.os, variant: nil)
                req.logger.info("\(body.Image) has no arm64 variant — falling back to amd64 (Rosetta)")
                img = try await ClientImage.fetch(
                    reference: body.Image,
                    platform: amd64,
                    containerSystemConfig: systemConfig
                )
                requestedPlatform = amd64
            }

            // Unpack a fetched image before use
            try await img.getCreateSnapshot(
                platform: requestedPlatform
            )

            let kernel = try await ClientKernel.getDefaultKernel(for: .current)

            let initImage = try await ClientImage.fetch(
                reference: systemConfig.vminit.image, platform: .current,
                containerSystemConfig: systemConfig
            )

            _ = try await initImage.getCreateSnapshot(
                platform: .current)

            let imageConfig = try await img.config(for: requestedPlatform).config

            let defaultUser: ProcessConfiguration.User = {
                if let u = imageConfig?.user {
                    return .raw(userString: u)
                }
                return .id(uid: 0, gid: 0)
            }()

            let workingDirectory = imageConfig?.workingDir ?? "/"

            let imageConfigEnvironment = imageConfig?.env ?? []
            let requestedEnvironment = body.Env ?? []
            // merge environment variables, with request taking precedence
            let mergedEnv = try Parser.allEnv(imageEnvs: imageConfigEnvironment, envFiles: [], envs: requestedEnvironment)

            // Inside a VM 127.0.0.1 is the container's own loopback, not the host. Rewrite
            // URL-form connection strings to the vmnet gateway. host-mode containers are
            // excluded — they stay on "default" with loopback DNS so NPM imports fail fast.
            var finalEnv = mergedEnv
            let envNetworkKeys = body.NetworkingConfig?.EndpointsConfig.map { Array($0.keys) } ?? []
            let isHostMode = body.HostConfig?.NetworkMode == "host"
            // Compute once; both rewrite blocks share the same named-network context.
            let namedNet = ContainerCreateRoute.firstNamedNetwork(
                endpointsConfigKeys: envNetworkKeys,
                networkMode: body.HostConfig?.NetworkMode
            )
            if let firstNet = namedNet,
                let networkResource = try? await NetworkClient().get(id: firstNet)
            {
                let gatewayIP = networkResource.status.ipv4Gateway.description
                if !gatewayIP.isEmpty && gatewayIP != "0.0.0.0" {
                    let rewritten = ContainerCreateRoute.rewriteLoopbackToGateway(mergedEnv, gatewayIP: gatewayIP)
                    if rewritten != mergedEnv {
                        req.logger.info("[network] rewrote 127.0.0.1→\(gatewayIP) in env vars for \(firstNet)")
                        finalEnv = rewritten
                    }
                }
            }

            // Also rewrite peer container hostnames → IPs in connection strings for named-network
            // containers. This bypasses the Rust DNS sidecar for inter-container DB connections:
            // under concurrent startup load the sidecar can drop responses causing auth/realtime/
            // storage to time out on DNS. Only @hostname:port and host=hostname DSN positions are
            // rewritten; IPs are a point-in-time snapshot so DNS remains the runtime path.
            // host-mode containers are excluded (they already get loopback DNS for fast-fail).
            if !isHostMode, namedNet != nil,
                let dnsServer = req.application.storage[SocktainerDNSServerKey.self]
            {
                let peers = dnsServer.listEntries()
                if !peers.isEmpty {
                    let hostRewrote = ContainerCreateRoute.rewritePeerHostnames(finalEnv, peers: peers)
                    if hostRewrote != finalEnv {
                        req.logger.info("[network] rewrote peer hostnames→IPs in env vars")
                        finalEnv = hostRewrote
                    }
                }
            }

            let publishedPorts: [PublishPort]
            do {
                publishedPorts = try convertPortBindings(
                    from: body.HostConfig?.PortBindings ?? [:]
                )
            } catch {
                req.logger.error("Failed to allocate ports: \(error)")
                throw Abort(.internalServerError, reason: "Failed to allocate ports: \(error)")
            }

            // Handle Entrypoint and Cmd from request, following Docker semantics
            var commandLine: [String] = []

            // Determine the entrypoint to use
            let entrypoint: [String]
            if let requestEntrypoint = body.Entrypoint {
                // If entrypoint is explicitly provided (even if empty), use it
                entrypoint = requestEntrypoint
            } else if let imageEntrypoint = imageConfig?.entrypoint {
                // Otherwise use image's entrypoint
                entrypoint = imageEntrypoint
            } else {
                // No entrypoint specified
                entrypoint = []
            }

            // Determine the command to use
            let command: [String]
            if let requestCmd = body.Cmd {
                // If cmd is explicitly provided but empty, use image's cmd
                command = requestCmd.isEmpty ? (imageConfig?.cmd ?? []) : requestCmd
            } else if body.Entrypoint != nil {
                // If entrypoint was explicitly overridden, don't use image's cmd
                command = []
            } else {
                // Use image's cmd
                command = imageConfig?.cmd ?? []
            }

            // Build final command line
            commandLine.append(contentsOf: entrypoint)
            commandLine.append(contentsOf: command)

            // Use working directory from request if provided and not empty, otherwise from image config
            let finalWorkingDirectory = (body.WorkingDir?.isEmpty == false) ? body.WorkingDir! : workingDirectory

            // Handle user from request if provided
            let finalUser: ProcessConfiguration.User = {
                if let requestUser = body.User {
                    return .raw(userString: requestUser)
                }
                return defaultUser
            }()

            // Ensure we have a valid executable
            guard let executable = commandLine.first, !executable.isEmpty else {
                req.logger.error("No executable specified for container")
                throw Abort(.badRequest, reason: "No executable specified for container. Image must specify ENTRYPOINT or CMD, or request must provide Entrypoint or Cmd.")
            }

            // For Apple Container compatibility, we ignore attach flags during creation
            // Containers are always created in detached mode and can be attached to later
            // TODO: Store attach flags (AttachStdin, AttachStdout, AttachStderr) in container metadata
            // for use when container is started via /start endpoint
            let processConfig = ProcessConfiguration(
                executable: executable,
                arguments: commandLine.dropFirst().map { String($0) },
                environment: finalEnv,
                workingDirectory: finalWorkingDirectory,
                terminal: body.Tty ?? false,
                user: finalUser,
            )

            var containerConfiguration = ContainerConfiguration(id: id, image: img.description, process: processConfig)
            containerConfiguration.platform = requestedPlatform
            containerConfiguration.stopSignal = requestedStopSignal
            containerConfiguration.shmSize = ContainerCreateRoute.shmSizeBytes(body.HostConfig?.ShmSize)
            containerConfiguration.capAdd = normalizedCapabilities.capAdd
            containerConfiguration.capDrop = normalizedCapabilities.capDrop
            containerConfiguration.readOnly = body.HostConfig?.ReadonlyRootfs ?? false
            containerConfiguration.useInit = body.HostConfig?.Init ?? false
            containerConfiguration.sysctls = body.HostConfig?.Sysctls ?? [:]

            // Enable Rosetta when running amd64 images if on arm64 host
            if Platform.current.architecture == "arm64" && requestedPlatform.architecture == "amd64" {
                containerConfiguration.rosetta = true
            }

            // Handle hostname from request - ensure uniqueness to avoid collision,
            // capped at 64 chars (Linux/VZ hostname limit; longer values fail start with EINVAL)
            let hostname = ContainerNameUtility.sanitize(
                (body.Hostname?.isEmpty == false) ? body.Hostname! : "\(id)-\(UUID().uuidString.lowercased())")

            // Handle networking configuration from request
            if let networkingConfig = body.NetworkingConfig,
                let endpointsConfig = networkingConfig.EndpointsConfig,
                !endpointsConfig.isEmpty
            {
                // Use networking config from request if provided
                containerConfiguration.networks = endpointsConfig.map { (networkName, _) in
                    let options = AttachmentOptions(hostname: hostname)
                    return AttachmentConfiguration(network: networkName, options: options)
                }
            } else if let networkingConfig = body.NetworkingConfig,
                let networks = networkingConfig.Networks,
                !networks.isEmpty
            {
                // Fallback to Networks field for backward compatibility
                containerConfiguration.networks = networks.map { (networkName, _) in
                    let options = AttachmentOptions(hostname: hostname)
                    return AttachmentConfiguration(network: networkName, options: options)
                }
            } else if let hostConfig = body.HostConfig,
                let networkMode = hostConfig.NetworkMode,
                !networkMode.isEmpty
            {
                // Apple Container is VM-based and does not support Linux-only network modes.
                // "host" and "none" have no equivalent; "bridge" is Docker's default bridge
                // which maps to Apple Container's "default". All three are silently remapped
                // to "default" so containers start instead of failing with "no network for id".
                let resolvedMode: String
                switch networkMode {
                case "host", "none", "bridge":
                    // Apple Container is VM-based: host/none/bridge have no equivalent.
                    // All remap to "default". host-mode containers rely on fast DNS failure
                    // (127.0.0.1 nameserver, see below) to avoid hanging on package downloads.
                    if networkMode != "bridge" {
                        req.logger.warning(
                            "network_mode '\(networkMode)' is not supported by Apple Container — remapping to 'default'"
                        )
                    }
                    resolvedMode = "default"
                default:
                    resolvedMode = networkMode
                }
                containerConfiguration.networks = [
                    AttachmentConfiguration(network: resolvedMode, options: AttachmentOptions(hostname: hostname))
                ]
            } else {
                // Fall back to default network if no networking config provided
                containerConfiguration.networks = [AttachmentConfiguration(network: "default", options: AttachmentOptions(hostname: hostname))]
            }

            containerConfiguration.publishedPorts = publishedPorts

            // Handle DNS configuration from request
            let nameservers = body.HostConfig?.Dns ?? []
            let searchDomains = body.HostConfig?.DnsSearch ?? []
            let dnsOptions = body.HostConfig?.DnsOptions ?? []
            let domain = (body.Domainname?.isEmpty == false) ? body.Domainname : nil

            // Always set DNS configuration to ensure /etc/resolv.conf is created
            // Even if empty, this ensures the file exists in the container
            containerConfiguration.dns = ContainerConfiguration.DNSConfiguration(
                nameservers: nameservers,
                domain: domain,
                searchDomains: searchDomains,
                options: dnsOptions
            )
            // Collect Compose service aliases from EndpointsConfig.
            // These are stored in a label so the start route can register them
            // in the DNS server once the container has an IP.
            let dnsNames =
                (body.NetworkingConfig?.EndpointsConfig?.values)
                .map { settings in settings.compactMap(\.Aliases).flatMap { $0 }.filter { !$0.isEmpty } }
                ?? []

            let originalLabels = body.Labels ?? [:]
            guard !LabelNormalization.containsReservedKey(originalLabels) else {
                throw Abort(.badRequest, reason: "Label key '\(LabelNormalization.mappingKey)' is reserved for internal use")
            }
            var containerLabels = LabelNormalization.sanitize(originalLabels)
            if let mapping = LabelNormalization.buildMapping(originalLabels) {
                containerLabels[LabelNormalization.mappingKey] = mapping
            }

            // Persist the requested healthcheck across create → start so the
            // start route can launch the probe loop and inspect can return it
            // in Config.Healthcheck. Apple Container has no native field for
            // this, so a JSON-encoded label is the carrier.
            if let healthcheck = body.Healthcheck {
                do {
                    let json = try JSONEncoder().encode(healthcheck)
                    if let jsonString = String(data: json, encoding: .utf8) {
                        containerLabels[HealthCheckManager.healthcheckLabel] = jsonString
                    }
                } catch {
                    req.logger.warning("Failed to encode healthcheck config: \(error) — healthcheck will not be persisted")
                }
            }

            if !dnsNames.isEmpty {
                containerLabels["socktainer.dns.names"] = dnsNames.joined(separator: ",")
            }

            // Ensure a DNS forwarder container for any named (non-default) network.
            // This covers both Docker Compose (EndpointsConfig.Aliases) and plain
            // `docker run --network <name>` (HostConfig.NetworkMode) — both need
            // DNS forwarder configured as the container's nameserver so container names
            // resolve inside the VM via SocktainerDNSServer.
            let endpointsKeys = body.NetworkingConfig?.EndpointsConfig.map { Array($0.keys) } ?? []
            let firstNamedNetwork = ContainerCreateRoute.firstNamedNetwork(
                endpointsConfigKeys: endpointsKeys,
                networkMode: body.HostConfig?.NetworkMode
            )
            if isHostMode {
                // host-mode containers get loopback (127.0.0.1) as their only nameserver.
                // Any external DNS lookup (e.g. Deno resolving registry.npmjs.org for an
                // `npm:` import) hits nothing on loopback and gets ECONNREFUSED in < 1 ms,
                // causing the process to fail immediately rather than hanging for minutes
                // on a SYN to an internet host that is unreachable from vmnet containers.
                let existing = containerConfiguration.dns
                containerConfiguration.dns = ContainerConfiguration.DNSConfiguration(
                    nameservers: ["127.0.0.1"],
                    domain: existing?.domain,
                    searchDomains: existing?.searchDomains ?? [],
                    options: existing?.options ?? []
                )
            } else if let firstNetwork = firstNamedNetwork,
                let dnsManager = req.application.storage[NetworkDNSManagerKey.self]
            {
                do {
                    let dnsIP = try await dnsManager.ensureDNSContainer(networkId: firstNetwork)
                    let existing = containerConfiguration.dns
                    containerConfiguration.dns = ContainerConfiguration.DNSConfiguration(
                        nameservers: [dnsIP],
                        domain: existing?.domain,
                        searchDomains: existing?.searchDomains ?? [],
                        options: existing?.options ?? []
                    )
                } catch {
                    req.logger.warning("Could not start DNS container for \(firstNetwork): \(error)")
                }
            }
            containerConfiguration.labels = containerLabels

            var resolvedMounts: [Filesystem] = []

            // Docker creates missing bind-mount source directories on the host automatically.
            // Parser.mounts() validates that the source path exists and throws if not, so we
            // must create missing directories BEFORE parsing, not after.
            // Socket files (.sock) are skipped: Apple Container uses virtiofs which shares
            // directories, not individual files or Unix domain sockets. Mounting a socket
            // would cause "operation not supported" at bootstrap time.
            let isSocketPath: (String) -> Bool = { $0.hasSuffix(".sock") || $0.hasSuffix(".socket") }
            if let binds = body.HostConfig?.Binds {
                for bind in binds {
                    let parts = bind.split(separator: ":").map(String.init)
                    if let source = parts.first, source.hasPrefix("/"), !isSocketPath(source) {
                        try? FileManager.default.createDirectory(
                            atPath: source, withIntermediateDirectories: true)
                    }
                }
            }
            if let mounts = body.HostConfig?.Mounts {
                for mount in mounts where mount.MountType.lowercased() == "bind" && !mount.Source.isEmpty && !isSocketPath(mount.Source) {
                    try? FileManager.default.createDirectory(
                        atPath: mount.Source, withIntermediateDirectories: true)
                }
            }

            // Process bind mounts from HostConfig.Binds — filter out socket files which
            // cannot be shared via virtiofs (Apple Container is VM-based).
            let filteredBinds = (body.HostConfig?.Binds ?? []).filter { bind in
                let source = bind.split(separator: ":").first.map(String.init) ?? ""
                if isSocketPath(source) {
                    req.logger.warning("bind mount '\(source)' is a Unix socket — skipped (not supported in Apple Container VMs)")
                    return false
                }
                return true
            }
            var volumesOrFs: [VolumeOrFilesystem] = []
            if !filteredBinds.isEmpty {
                volumesOrFs = try Parser.volumes(filteredBinds)
            }

            // Process mounts from HostConfig.Mounts
            var mountsOrFs: [VolumeOrFilesystem] = []
            if let mounts = body.HostConfig?.Mounts, !mounts.isEmpty {
                // Separate volume mounts from other mount types
                let volumeMounts = mounts.filter { $0.MountType.lowercased() == "volume" }
                let otherMounts = mounts.filter { $0.MountType.lowercased() != "volume" && !isSocketPath($0.Source) }

                // Handle volume mounts using the volume format (source:destination)
                if !volumeMounts.isEmpty {
                    let volumeStrings = volumeMounts.map { mount in
                        var volumeString = "\(mount.Source):\(mount.Target)"
                        if mount.ReadOnly == true {
                            volumeString += ":ro"
                        }
                        return volumeString
                    }
                    let volumeMountsOrFs = try Parser.volumes(volumeStrings)
                    mountsOrFs.append(contentsOf: volumeMountsOrFs)
                }

                // Handle other mount types (bind, tmpfs, etc.)
                if !otherMounts.isEmpty {
                    let mountStrings = otherMounts.map { mount in
                        var components: [String] = []

                        // Convert Docker mount type to Parser-supported type
                        let mountType = mount.MountType.lowercased() == "bind" ? "bind" : mount.MountType
                        components.append("type=\(mountType)")

                        // Add source if specified
                        if !mount.Source.isEmpty {
                            components.append("source=\(mount.Source)")
                        }

                        // Add destination/target
                        components.append("destination=\(mount.Target)")

                        // Add readonly flag if specified
                        if mount.ReadOnly == true {
                            components.append("ro")
                        }

                        return components.joined(separator: ",")
                    }
                    let otherMountsOrFs = try Parser.mounts(mountStrings)
                    mountsOrFs.append(contentsOf: otherMountsOrFs)
                }
            }

            // Resolve volumes from both volumes and mounts
            for item in (volumesOrFs + mountsOrFs) {
                switch item {
                case .filesystem(let fs):
                    resolvedMounts.append(fs)
                case .volume(let parsed):
                    // Check if volume exists by listing all volumes and finding a match
                    let existingVolumes = try await ClientVolume.list()
                    let existingVolume = existingVolumes.first { $0.name == parsed.name }

                    let volume: ContainerResource.VolumeConfiguration
                    if let existing = existingVolume {
                        volume = existing
                    } else {
                        // Volume doesn't exist, create it automatically (Docker behavior)
                        // might be revisited if https://github.com/apple/container/issues/690 is closed
                        req.logger.debug("Volume '\(parsed.name)' not found, creating it automatically")
                        volume = try await ClientVolume.create(
                            name: parsed.name,
                            driver: "local",
                            driverOpts: [:],
                            labels: [:]
                        )
                    }

                    // Strip /lost+found when PGDATA is set (any value) — that
                    // reliably signals a Postgres container, and named volumes are
                    // always mounted at their root so /lost+found is always reachable.
                    if VolumeImageCleaner.isPostgresDataVolume(mergedEnv: mergedEnv),
                        volume.format == "ext4",
                        VolumeImageCleaner.isEnabled(labels: volume.labels)
                    {
                        VolumeImageCleaner.removeLostFound(imagePath: volume.source, logger: req.logger)
                    }

                    // Per-volume sync label wins; fall back to global --volume-sync (default: nosync).
                    let syncMode =
                        volume.labels[Filesystem.SyncMode.socktainerLabel]
                        .flatMap { Filesystem.SyncMode(rawString: $0) }
                        ?? req.application.storage[VolumeSyncModeKey.self]
                        ?? .nosync
                    let volumeMount = Filesystem.volume(
                        name: parsed.name,
                        format: volume.format,
                        source: volume.source,
                        destination: parsed.destination,
                        options: parsed.options,
                        sync: syncMode
                    )
                    resolvedMounts.append(volumeMount)
                }
            }

            containerConfiguration.mounts = resolvedMounts

            if let memoryBytes = resolveMemoryInBytes(body.HostConfig?.Memory) {
                containerConfiguration.resources.memoryInBytes = memoryBytes
            }

            if let nanoCpus = body.HostConfig?.NanoCpus, nanoCpus > 0 {
                containerConfiguration.resources.cpus = ContainerCreateRoute.vCpus(fromNanoCpus: nanoCpus)
            }

            let options = ContainerCreateOptions(autoRemove: body.HostConfig?.AutoRemove ?? false)
            let container: ContainerSnapshot
            do {
                let containerClient = ContainerClient()
                try await containerClient.create(configuration: containerConfiguration, options: options, kernel: kernel)
                container = try await containerClient.get(id: containerConfiguration.id)
                req.logger.debug("Container created successfully with ID: \(container.id)")
            } catch {
                req.logger.error("Failed to create container: \(error)")
                throw Abort(.internalServerError, reason: "Failed to create container: \(error)")
            }

            let hexId = DockerContainerID.hexId(for: container)
            // Record --rm intent so the post-exit `destroy` event fires (and fires exactly once):
            // Apple Container reaps the container itself, so no DELETE arrives. The flag is consumed
            // by whichever path observes the exit — foreground attach or the detached die observer.
            if options.autoRemove {
                await ContainerInfoCache.shared.markAutoRemove(hexId: hexId, nativeId: container.id)
            }
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(ContainerCreateRoute.makeCreateEvent(for: container))
            }
            // Docker Engine API: POST /containers/create returns 201 Created.
            let createResponse = RESTContainerCreate(Id: hexId, Warnings: [])
            let httpResponse = try await createResponse.encodeResponse(for: req)
            httpResponse.status = .created
            return httpResponse
        }
    }

    /// Returns the network name that should receive a DNS forwarder sidecar, or `nil` if the
    /// container uses the default (non-named) network and no DNS setup is needed.
    ///
    /// Covers both Compose (`EndpointsConfig`) and plain `docker run --network <name>`
    /// (`HostConfig.NetworkMode`). Reserved non-routable modes — "default", "bridge",
    /// "host", "none" — are excluded because they either don't support user-defined name
    /// resolution or are handled by the host's own DNS.
    ///
    /// Extracted so the selection logic can be asserted in unit tests independently of
    /// the full handler, which drives Apple Container APIs.
    ///
    /// Pass `endpointsConfigKeys` as `Array(body.NetworkingConfig?.EndpointsConfig?.keys ?? [])`.
    static func firstNamedNetwork(endpointsConfigKeys: [String], networkMode: String?) -> String? {
        let reservedModes: Set<String> = ["default", "bridge", "host", "none"]
        if let net = endpointsConfigKeys.first(where: { !$0.isEmpty && !reservedModes.contains($0) }) { return net }
        if let mode = networkMode, !mode.isEmpty, !reservedModes.contains(mode) { return mode }
        return nil
    }

    /// Mirrors moby's ShmSize handling: a positive request is used verbatim; 0 or omitted
    /// falls back to Docker's DefaultShmSize (64 MiB). Negative is rejected earlier with 400.
    static let defaultShmSize: UInt64 = 64 * 1024 * 1024

    static func shmSizeBytes(_ raw: Int?) -> UInt64 {
        guard let raw, raw > 0 else { return defaultShmSize }
        return UInt64(raw)
    }

    /// Rewrite `127.0.0.1:PORT` → `gatewayIP:PORT` in URL-form env vars (`@` or `://` prefix).
    /// Bind-address vars like `LISTEN=127.0.0.1:80` are left unchanged.
    static func rewriteLoopbackToGateway(_ envVars: [String], gatewayIP: String) -> [String] {
        envVars.map {
            $0.replacingOccurrences(
                of: #"(@|://)127\.0\.0\.1:(\d+)"#,
                with: "$1\(gatewayIP):$2",
                options: .regularExpression
            )
        }
    }

    /// Rewrite known container hostnames to their IPs in `@hostname:port` and `host=hostname`
    /// connection-string positions. Bypasses DNS for inter-container connections at startup.
    static func rewritePeerHostnames(_ envVars: [String], peers: [String: String]) -> [String] {
        envVars.map { env in
            var result = env
            for (rawName, ip) in peers {
                let escaped = NSRegularExpression.escapedPattern(for: rawName)
                // URL form: @hostname:port or ://hostname:port
                result = result.replacingOccurrences(
                    of: "(@|://)\(escaped):(\\d+)", with: "$1\(ip):$2", options: .regularExpression)
                // PostgreSQL key-value form: `host=hostname` followed by a DSN separator
                // (space, end-of-string, & or ?) — prevents a short name like "db" from
                // matching inside "olddb" or "database".
                result = result.replacingOccurrences(
                    of: "host=\(escaped)(?=[\\s?&]|$)",
                    with: "host=\(ip)",
                    options: .regularExpression
                )
            }
            return result
        }
    }

    static func makeCreateEvent(for container: ContainerSnapshot) -> DockerEvent {
        DockerEvent.simpleEvent(
            id: DockerContainerID.hexId(for: container),
            type: "container",
            status: "create",
            image: container.configuration.image.reference,
            name: container.id,
            labels: LabelNormalization.restore(container.configuration.labels)
        )
    }

    /// Mirrors moby's daemon_unix.go cpu subsystem checks (v28.5.2): NanoCpus and the CFS
    /// period/quota knobs are mutually exclusive, NanoCpus must fall within the host's core
    /// count, and CpuShares must be a positive weight. Returns the moby-verbatim error message
    /// to send as a 400, or nil if the request is valid.
    static func validateCpuLimits(hostConfig: HostConfig?) -> String? {
        let nanoCpus = hostConfig?.NanoCpus ?? 0
        let cpuPeriod = hostConfig?.CpuPeriod ?? 0
        let cpuQuota = hostConfig?.CpuQuota ?? 0
        let cpuShares = hostConfig?.CpuShares ?? 0

        if nanoCpus > 0 && cpuPeriod > 0 {
            return "Conflicting options: Nano CPUs and CPU Period cannot both be set"
        }
        if nanoCpus > 0 && cpuQuota > 0 {
            return "Conflicting options: Nano CPUs and CPU Quota cannot both be set"
        }
        if nanoCpus != 0 {
            let hostCores = ProcessInfo.processInfo.activeProcessorCount
            if nanoCpus < 0 || nanoCpus > hostCores * 1_000_000_000 {
                return "range of CPUs is from 0.01 to \(hostCores).00, as there are only \(hostCores) CPUs available"
            }
        }
        if cpuShares < 0 {
            return "invalid CPU shares (\(cpuShares)): value must be a positive integer"
        }
        return nil
    }

    /// Docker's `--cpus` (NanoCpus, billionths of a CPU) is a fractional CFS quota; Apple's
    /// `resources.cpus` is a whole vCPU count provisioned to the container's VM. Floors rather
    /// than rounds — `--cpus` is a cap, so flooring never grants more compute than requested
    /// (a sub-1-core request like 0.5 still needs at least one whole vCPU to run at all).
    static func vCpus(fromNanoCpus nanoCpus: Int) -> Int {
        max(1, nanoCpus / 1_000_000_000)
    }
}
// Function to convert PortBindings from HostConfig to PublishedPorts
/*

    // handle PortBindings from HostConfig
    // example:
    //     "PortBindings":{
    //      "5432/tcp":[
    //         {
    //            "HostIp":"",
    //            "HostPort":""
    //         }
    //      ]
    //   },

    // needs to be converted to
    "publishedPorts": [
        {
          "hostAddress": "0.0.0.0",
          "containerPort": 5432,
          "hostPort": 5432,
          "proto": "tcp"
        }
      ],
*/
func convertPortBindings(from portBindings: [String: [PortBinding]]) throws -> [PublishPort] {
    var publishedPorts: [PublishPort] = []

    for (portSpec, bindings) in portBindings {
        // Parse the port specification (e.g., "5432/tcp")
        let components = portSpec.split(separator: "/")
        guard components.count == 2,
            let containerPort = UInt16(components[0])
        else {
            continue  // Skip invalid port specifications
        }

        let protoString = String(components[1])
        guard let proto = PublishProtocol(rawValue: protoString) else {
            continue  // Skip unsupported protocols
        }

        // Process each binding for this port
        for binding in bindings {
            // Use default values if not specified
            let hostAddress = binding.HostIp?.isEmpty == false ? binding.HostIp! : "0.0.0.0"

            // If HostPort is empty/nil, find an available port
            let hostPort: UInt16
            if let hostPortString = binding.HostPort, !hostPortString.isEmpty {
                if let parsedPort = UInt16(hostPortString) {
                    hostPort = parsedPort
                } else {
                    hostPort = UInt16(try findAvailablePort())
                }
            } else {
                hostPort = UInt16(try findAvailablePort())
            }

            let publishPort = try PublishPort(
                hostAddress: try IPAddress(hostAddress),
                hostPort: hostPort,
                containerPort: containerPort,
                proto: proto,
                count: 1
            )

            publishedPorts.append(publishPort)
        }
    }

    return publishedPorts
}

// Maps Docker HostConfig.Memory (bytes, 0 = no limit) to Apple Container memoryInBytes.
// Returns nil when the value is absent, zero, or negative so the Apple Container
// default (1 GiB) is preserved.
func resolveMemoryInBytes(_ memory: Int?) -> UInt64? {
    guard let memory, memory > 0 else { return nil }
    return UInt64(memory)
}
