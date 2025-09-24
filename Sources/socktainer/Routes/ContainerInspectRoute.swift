import ContainerClient
import Containerization
import Vapor

struct ContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", ":id", "json", use: ContainerInspectRoute.handler(client: client))
        // also handle without version prefix
        routes.get("containers", ":id", "json", use: ContainerInspectRoute.handler(client: client))

    }
}

extension ContainerInspectRoute {
    private static func getUserString(from user: ProcessConfiguration.User) -> String? {
        switch user {
        case .raw(let userString):
            return userString.isEmpty ? nil : userString
        case .id(let uid, let gid):
            return "\(uid):\(gid)"
        }
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> RESTContainerInspect {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            let exposedPorts = Dictionary(
                uniqueKeysWithValues:
                    container.configuration.publishedPorts.map {
                        ("\($0.containerPort)/\($0.proto.rawValue)", EmptyObject())
                    }
            )

            let containerConfig: ContainerConfig = ContainerConfig(
                Hostname: container.id,  // Use container ID as hostname since hostName property doesn't exist
                Domainname: container.configuration.dns?.domain,
                User: getUserString(from: container.configuration.initProcess.user),
                AttachStdin: false,  // no mechanism to derive this value
                AttachStdout: true,  // no mechanism to derive this value
                AttachStderr: true,  // no mechanism to derive this value
                ExposedPorts: exposedPorts.isEmpty ? nil : exposedPorts,
                Tty: container.configuration.initProcess.terminal,
                OpenStdin: false,  // no mechanism to derive this value
                StdinOnce: false,  // no mechanism to derive this value
                Env: container.configuration.initProcess.environment.isEmpty ? nil : container.configuration.initProcess.environment,
                Cmd: container.configuration.initProcess.arguments.isEmpty ? nil : container.configuration.initProcess.arguments,
                Healthcheck: nil,  // Apple containers don't have a healthcheck
                ArgsEscaped: false,  // no mechanism to derive this value
                Image: container.configuration.image.reference,
                Volumes: nil,  // Could be derived from mounts if needed
                WorkingDir: container.configuration.initProcess.workingDirectory.isEmpty ? nil : container.configuration.initProcess.workingDirectory,
                Entrypoint: [container.configuration.initProcess.executable],
                NetworkDisabled: container.networks.isEmpty,
                MacAddress: nil,  // no mechanism to derive this value
                OnBuild: nil,  // no mechanism to derive this value
                Labels: container.configuration.labels.isEmpty ? nil : container.configuration.labels,
                StopSignal: nil,  // no mechanism to derive this value
                StopTimeout: nil,  // no mechanism to derive this value
                Shell: nil  // no mechanism to derive this value
            )

            let mounts = container.configuration.mounts.map { mount in
                let mountType: String
                let mountName: String?
                let driver: String?

                switch mount.type {
                case .block(_, _, _):
                    mountType = "bind"
                    mountName = nil
                    driver = nil
                case .volume(let name, _, _, _):
                    mountType = "volume"
                    mountName = name
                    driver = "local"
                case .virtiofs:
                    mountType = "bind"
                    mountName = nil
                    driver = nil
                case .tmpfs:
                    mountType = "tmpfs"
                    mountName = nil
                    driver = nil
                }

                let isReadonly = mount.options.readonly
                let mode = isReadonly ? "ro" : "rw"

                return ContainerMountPoint(
                    type: mountType,
                    name: mountName,
                    source: mount.source,
                    destination: mount.destination,
                    driver: nil,  // we do not take into account any storage driver at this time
                    mode: mode,
                    rw: !isReadonly,
                    propagation: ""
                )
            }

            // Create enhanced HostConfig - using default initializer since struct has many optional fields
            let hostConfig: HostConfig = HostConfig()

            // Enhanced network settings with proper port mapping
            let networkSettings = ContainerNetworkSettings(
                Bridge: nil,
                SandboxID: nil,
                Ports: Dictionary(grouping: container.configuration.publishedPorts, by: { "\($0.containerPort)/\($0.proto.rawValue)" })
                    .mapValues { bindings in
                        bindings.map { PortBinding(HostIp: $0.hostAddress, HostPort: "\($0.hostPort)") }
                    },
                SandboxKey: nil,
                Networks: Dictionary(
                    uniqueKeysWithValues: container.networks.map { attachment in
                        let endpoint = ContainerEndpointSettings(
                            IPAMConfig: nil,
                            Links: nil,
                            Aliases: nil,
                            NetworkID: attachment.network,
                            EndpointID: nil,
                            Gateway: stripSubnetFromIP(attachment.gateway),
                            IPAddress: stripSubnetFromIP(attachment.address),
                            IPPrefixLen: nil,
                            IPv6Gateway: nil,
                            GlobalIPv6Address: nil,
                            GlobalIPv6PrefixLen: nil,
                            MacAddress: nil,
                            DriverOpts: nil
                        )
                        return (attachment.network, endpoint)
                    }
                ),
                EndpointsConfig: Dictionary(
                    uniqueKeysWithValues: container.networks.map { attachment in
                        let endpoint = ContainerEndpointSettings(
                            IPAMConfig: nil,
                            Links: nil,
                            Aliases: nil,
                            NetworkID: attachment.network,
                            EndpointID: nil,
                            Gateway: stripSubnetFromIP(attachment.gateway),
                            IPAddress: stripSubnetFromIP(attachment.address),
                            IPPrefixLen: nil,
                            IPv6Gateway: nil,
                            GlobalIPv6Address: nil,
                            GlobalIPv6PrefixLen: nil,
                            MacAddress: nil,
                            DriverOpts: nil
                        )
                        return (attachment.network, endpoint)
                    }
                )
            )

            // Enhanced container state with better timestamp handling

            let containerState: ContainerState = ContainerState(
                Status: container.status.rawValue,
                Running: container.status == .running,
                Paused: false,  // Apple containers don't have a paused state like Docker
                Restarting: false,
                OOMKilled: false,
                Dead: container.status == .stopped,
                Pid: 0,  // we have no mechanism to derive PID in Apple container
                ExitCode: container.status == .stopped ? 0 : 0,
                Error: "",
                StartedAt: container.status == .running ? "1970-01-01T00:00:00.000000000Z" : "",
                FinishedAt: container.status == .stopped ? "1970-01-01T00:00:00.000000000Z" : ""
            )

            return RESTContainerInspect(
                Id: container.id,
                Created: "1970-01-01T00:00:00.000000000Z",  // Default to epoch time for Apple containers
                Path: container.configuration.initProcess.executable,
                Args: container.configuration.initProcess.arguments,
                State: containerState,
                Image: container.configuration.image.reference,
                ResolvConfPath: "/etc/resolv.conf",
                HostnamePath: "/etc/hostname",
                HostsPath: "/etc/hosts",
                LogPath: nil,  // Apple containers don't have a log path
                Name: "/" + container.id,
                RestartCount: 0,
                Driver: "",
                Platform: "linux",
                ImageManifestDescriptor: nil,
                MountLabel: "",
                ProcessLabel: "",
                AppArmorProfile: "",
                ExecIDs: nil,
                HostConfig: hostConfig,
                GraphDriver: ContainerDriverData(Name: "", Data: [:]),
                SizeRw: nil,
                SizeRootFs: nil,
                Mounts: mounts,
                Config: containerConfig,
                NetworkSettings: networkSettings
            )
        }
    }
}
