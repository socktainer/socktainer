import ContainerAPIClient
import ContainerResource
import Containerization
import Vapor

struct ContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/json", use: ContainerInspectRoute.handler(client: client))
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

    /// Apple Container only reports live network attachments while a
    /// container is running (`container.networks` is hardcoded to `[]` once
    /// stopped), whereas Docker's `NetworkSettings.Networks` reflects the
    /// container's configured attachments regardless of run state. Falling
    /// back to the persisted `configuration.networks` keeps that parity,
    /// though the IP/gateway are unknown without a live sandbox.
    private static func networkEndpoints(for container: ContainerSnapshot) -> [String: ContainerEndpointSettings] {
        // uniquingKeysWith rather than uniqueKeysWithValues: nothing in Attachment's array-based
        // storage guarantees distinct .network names, and a duplicate would otherwise trap.
        if !container.networks.isEmpty {
            return Dictionary(
                container.networks.map { attachment in
                    (
                        attachment.network,
                        ContainerEndpointSettings(
                            IPAMConfig: nil,
                            Links: nil,
                            Aliases: nil,
                            NetworkID: attachment.network,
                            EndpointID: nil,
                            Gateway: stripSubnetFromIP(String(describing: attachment.ipv4Gateway)),
                            IPAddress: stripSubnetFromIP(String(describing: attachment.ipv4Address)),
                            IPPrefixLen: nil,
                            IPv6Gateway: nil,
                            GlobalIPv6Address: nil,
                            GlobalIPv6PrefixLen: nil,
                            MacAddress: nil,
                            DriverOpts: nil
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return Dictionary(
            container.configuration.networks.map { attachment in
                (
                    attachment.network,
                    ContainerEndpointSettings(
                        IPAMConfig: nil,
                        Links: nil,
                        Aliases: nil,
                        NetworkID: attachment.network,
                        EndpointID: nil,
                        Gateway: nil,
                        IPAddress: nil,
                        IPPrefixLen: nil,
                        IPv6Gateway: nil,
                        GlobalIPv6Address: nil,
                        GlobalIPv6PrefixLen: nil,
                        MacAddress: nil,
                        DriverOpts: nil
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
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

            // Apple Container has no native healthcheck field; we round-trip
            // the original config via a JSON-encoded label set by the create
            // route, so Compose / Docker clients see the same Healthcheck
            // block they sent.
            let healthcheckConfig: HealthcheckConfig? =
                container.configuration.labels[HealthCheckManager.healthcheckLabel]
                .flatMap { Data($0.utf8) }
                .flatMap { try? JSONDecoder().decode(HealthcheckConfig.self, from: $0) }

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
                Healthcheck: healthcheckConfig,
                ArgsEscaped: false,  // no mechanism to derive this value
                Image: container.configuration.image.reference,
                Volumes: nil,  // Could be derived from mounts if needed
                WorkingDir: container.configuration.initProcess.workingDirectory.isEmpty ? nil : container.configuration.initProcess.workingDirectory,
                Entrypoint: [container.configuration.initProcess.executable],
                NetworkDisabled: container.configuration.networks.isEmpty,
                MacAddress: nil,  // no mechanism to derive this value
                OnBuild: nil,  // no mechanism to derive this value
                Labels: {
                    let restored = LabelNormalization.restore(container.configuration.labels)
                    return restored.isEmpty ? nil : restored
                }(),
                StopSignal: container.configuration.stopSignal,
                StopTimeout: nil,  // no mechanism to derive this value
                Shell: nil  // no mechanism to derive this value
            )

            let mounts = container.configuration.mounts.map { mount in
                let mountType: String
                let mountName: String?

                switch mount.type {
                case .block(_, _, _):
                    mountType = "bind"
                    mountName = nil
                case .volume(let name, _, _, _):
                    mountType = "volume"
                    mountName = name
                case .virtiofs:
                    mountType = "bind"
                    mountName = nil
                case .tmpfs:
                    mountType = "tmpfs"
                    mountName = nil
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
            let networkEndpoints = Self.networkEndpoints(for: container)
            let networkSettings = ContainerNetworkSettings(
                Bridge: nil,
                SandboxID: nil,
                Ports: Dictionary(grouping: container.configuration.publishedPorts, by: { "\($0.containerPort)/\($0.proto.rawValue)" })
                    .mapValues { bindings in
                        bindings.map { PortBinding(HostIp: $0.hostAddress.description, HostPort: "\($0.hostPort)") }
                    },
                SandboxKey: nil,
                Networks: networkEndpoints,
                EndpointsConfig: networkEndpoints
            )

            let createdAt = AppleContainerTimestampResolver.containerCreationDate(container)

            // Live healthcheck status, if a probe loop is running for this
            // container. Returns nil when no healthcheck is configured or
            // the loop hasn't recorded its first result yet.
            let health = await req.application.storage[HealthCheckManagerKey.self]?.currentHealth(for: container.id)

            let containerState: ContainerState = ContainerState(
                Status: container.status.mobyState,
                Running: container.status == .running,
                Paused: false,  // Apple containers don't have a paused state like Docker
                Restarting: false,
                OOMKilled: false,
                Dead: container.status == .stopped,
                Pid: 0,  // we have no mechanism to derive PID in Apple container
                ExitCode: container.status == .stopped ? 0 : 0,
                Error: "",
                StartedAt: container.startedDate.map { AppleContainerTimestampResolver.iso8601Timestamp($0) } ?? "",
                FinishedAt: container.status == .stopped ? "1970-01-01T00:00:00.000000000Z" : "",
                Health: health
            )

            return RESTContainerInspect(
                Id: DockerContainerID.hexId(for: container),
                Created: AppleContainerTimestampResolver.iso8601Timestamp(createdAt),
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
