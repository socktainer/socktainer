import ContainerClient
import ContainerNetworkService
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Vapor

struct ContainerCreateRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", use: ContainerCreateRoute.handler(client: client))
        // also handle without version prefix
        routes.post("containers", ":id", use: ContainerCreateRoute.handler(client: client))
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
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> RESTContainerCreate {
        { req in
            let query = try req.query.decode(ContainerCreateQuery.self)

            let containerName = query.name

            // use platform "" if not provided
            let containerPlatform = query.platform ?? "linux/\(Arch.hostArchitecture().rawValue)"

            // body contains the Image
            let body = try req.content.decode(CreateContainerRequest.self)

            req.logger.info("Creating container for image: \(body.Image)")

            let id = Utility.createContainerID(name: containerName)
            try Utility.validEntityName(id)

            // Validate the requested platform only if provided
            let requestedPlatform = try Platform(from: containerPlatform)

            let img = try await ClientImage.fetch(
                reference: body.Image,
                platform: requestedPlatform,
            )

            // Unpack a fetched image before use
            try await img.getCreateSnapshot(
                platform: requestedPlatform
            )

            let kernel = try await ClientKernel.getDefaultKernel(for: .current)

            let initImage = try await ClientImage.fetch(
                reference: ClientImage.initImageRef, platform: .current
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

            // Use working directory from request if provided, otherwise from image config
            let finalWorkingDirectory = body.WorkingDir ?? workingDirectory

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

            // Handle hostname from request - ensure uniqueness to avoid collision
            let hostname = (body.Hostname?.isEmpty == false) ? body.Hostname! : "\(id)-\(UUID().uuidString.lowercased())"

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
            containerConfiguration.labels = body.Labels ?? [:]

            var resolvedMounts: [Filesystem] = []

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
                    do {
                        let volume = try await ClientVolume.inspect(parsed.name)
                        let volumeMount = Filesystem.volume(
                            name: parsed.name,
                            format: volume.format,
                            source: volume.source,
                            destination: parsed.destination,
                            options: parsed.options
                        )
                        resolvedMounts.append(volumeMount)
                    } catch {
                        throw ContainerizationError(.invalidArgument, message: "volume '\(parsed.name)' not found")
                    }
                }
            }

            containerConfiguration.mounts = resolvedMounts

            let options = ContainerCreateOptions(autoRemove: body.HostConfig?.AutoRemove ?? false)
            let container: ClientContainer
            do {
                container = try await ClientContainer.create(configuration: containerConfiguration, options: options, kernel: kernel)
                req.logger.debug("Container created successfully with ID: \(container.id)")
            } catch {
                req.logger.error("Failed to create container: \(error)")
                throw Abort(.internalServerError, reason: "Failed to create container: \(error)")
            }

            return RESTContainerCreate(
                Id: container.id,
                Warning: []
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
            let containerPort = Int(components[0])
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
            let hostPort: Int
            if let hostPortString = binding.HostPort, !hostPortString.isEmpty {
                hostPort = try Int(hostPortString) ?? findAvailablePort()
            } else {
                hostPort = try findAvailablePort()
            }

            let publishPort = PublishPort(
                hostAddress: hostAddress,
                hostPort: hostPort,
                containerPort: containerPort,
                proto: proto
            )

            publishedPorts.append(publishPort)
        }
    }

    return publishedPorts
}
