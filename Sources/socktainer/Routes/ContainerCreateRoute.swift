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

            let publishedPorts: [PublishPort] = convertPortBindings(
                from: body.HostConfig?.PortBindings ?? [:]
            )

            // create full command line by appending imageConfig.entrypoint and imageConfig.cmd
            var fullCommand: [String] = []
            if let entrypoint = imageConfig?.entrypoint {
                fullCommand.append(contentsOf: entrypoint)
            }
            if let cmd = imageConfig?.cmd {
                fullCommand.append(contentsOf: cmd)
            }

            let processConfig = ProcessConfiguration(
                executable: fullCommand.first ?? "",
                arguments: fullCommand.dropFirst().map { String($0) },
                environment: mergedEnv,
                workingDirectory: workingDirectory,
                terminal: false,
                user: defaultUser,
            )

            var containerConfiguration = ContainerConfiguration(id: id, image: img.description, process: processConfig)
            containerConfiguration.platform = requestedPlatform

            containerConfiguration.networks = [AttachmentConfiguration(network: "default", options: AttachmentOptions(hostname: id))]
            containerConfiguration.publishedPorts = publishedPorts

            let options = ContainerCreateOptions(autoRemove: false)
            let container = try await ClientContainer.create(configuration: containerConfiguration, options: options, kernel: kernel)

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
func convertPortBindings(from portBindings: [String: [PortBinding]]) -> [PublishPort] {
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
            let hostPort = binding.HostPort?.isEmpty == false ? (Int(binding.HostPort!) ?? containerPort) : containerPort

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
