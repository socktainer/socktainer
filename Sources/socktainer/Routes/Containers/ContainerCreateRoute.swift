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
    static func handler(client: ClientContainerProtocol, systemConfig: ContainerSystemConfig) -> @Sendable (Request) async throws -> RESTContainerCreate {
        { req in
            let query = try req.query.decode(ContainerCreateQuery.self)

            let containerName = query.name

            // use platform "" if not provided
            let containerPlatform = (query.platform?.isEmpty == false) ? query.platform! : "linux/\(Arch.hostArchitecture().rawValue)"

            let bodyData = try await req.body.collect().get()!
            let body = try JSONDecoder().decode(CreateContainerRequest.self, from: bodyData.getData(at: 0, length: bodyData.readableBytes)!)

            req.logger.info("Creating container for image: \(body.Image)")

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
                environment: mergedEnv,
                workingDirectory: finalWorkingDirectory,
                terminal: body.Tty ?? false,
                user: finalUser,
            )

            var containerConfiguration = ContainerConfiguration(id: id, image: img.description, process: processConfig)
            containerConfiguration.platform = requestedPlatform

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
                // Use NetworkMode from HostConfig
                containerConfiguration.networks = [AttachmentConfiguration(network: networkMode, options: AttachmentOptions(hostname: hostname))]
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

                // Ensure a CoreDNS container for the first network and point this
                // container's DNS at it so service names resolve inside the VM.
                if let dnsManager = req.application.storage[NetworkDNSManagerKey.self],
                    let firstNetwork = body.NetworkingConfig?.EndpointsConfig?.keys.first
                {
                    do {
                        let dnsIP = try await dnsManager.ensureDNSContainer(networkId: firstNetwork)
                        let existing = containerConfiguration.dns
                        containerConfiguration.dns = ContainerConfiguration.DNSConfiguration(
                            nameservers: [dnsIP],
                            domain: existing?.domain ?? nil,
                            searchDomains: existing?.searchDomains ?? [],
                            options: existing?.options ?? []
                        )
                    } catch {
                        req.logger.warning("Could not start DNS container for \(firstNetwork): \(error)")
                    }
                }
            }
            containerConfiguration.labels = containerLabels

            var resolvedMounts: [Filesystem] = []

            // Docker creates missing bind-mount source directories on the host automatically.
            // Parser.mounts() validates that the source path exists and throws if not, so we
            // must create missing directories BEFORE parsing, not after.
            if let binds = body.HostConfig?.Binds {
                for bind in binds {
                    let parts = bind.split(separator: ":").map(String.init)
                    if let source = parts.first, source.hasPrefix("/") {
                        try? FileManager.default.createDirectory(
                            atPath: source, withIntermediateDirectories: true)
                    }
                }
            }
            if let mounts = body.HostConfig?.Mounts {
                for mount in mounts where mount.MountType.lowercased() == "bind" && !mount.Source.isEmpty {
                    try? FileManager.default.createDirectory(
                        atPath: mount.Source, withIntermediateDirectories: true)
                }
            }

            // Process bind mounts from HostConfig.Binds
            var volumesOrFs: [VolumeOrFilesystem] = []
            if let binds = body.HostConfig?.Binds, !binds.isEmpty {
                volumesOrFs = try Parser.volumes(binds)
            }

            // Process mounts from HostConfig.Mounts
            var mountsOrFs: [VolumeOrFilesystem] = []
            if let mounts = body.HostConfig?.Mounts, !mounts.isEmpty {
                // Separate volume mounts from other mount types
                let volumeMounts = mounts.filter { $0.MountType.lowercased() == "volume" }
                let otherMounts = mounts.filter { $0.MountType.lowercased() != "volume" }

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

                    // Strip /lost+found when PGDATA matches this volume's destination.
                    // Every official Postgres image sets PGDATA as a Docker ENV, so
                    // this reliably targets the exact volume that initdb will reject.
                    let pgdata =
                        mergedEnv
                        .first(where: { $0.hasPrefix("PGDATA=") })
                        .map { String($0.dropFirst("PGDATA=".count)) }
                    if let pgdata, parsed.destination == pgdata,
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

            return RESTContainerCreate(
                Id: DockerContainerID.hexId(for: container),
                Warnings: []
            )
        }
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
