import ContainerClient
import ContainerNetworkService
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

            // Handle Entrypoint and Cmd from request, falling back to image config
            var commandLine: [String] = []
            if let requestEntrypoint = body.Entrypoint, !requestEntrypoint.isEmpty {
                commandLine.append(contentsOf: requestEntrypoint)
            } else if let imageEntrypoint = imageConfig?.entrypoint {
                commandLine.append(contentsOf: imageEntrypoint)
            }

            if let requestCmd = body.Cmd, !requestCmd.isEmpty {
                commandLine.append(contentsOf: requestCmd)
            } else if let imageCmd = imageConfig?.cmd {
                commandLine.append(contentsOf: imageCmd)
            }

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
