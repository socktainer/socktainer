import ContainerAPIClient
import ContainerNetworkClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import Foundation
import Logging
import Vapor

struct NetworkDNSManagerKey: StorageKey {
    typealias Value = NetworkDNSManager
}

/// Manages one CoreDNS sidecar container per user-created network.
///
/// Each CoreDNS container is configured to forward all DNS queries to
/// SocktainerDNSServer running on the host (reachable at the network's
/// gateway IP on port 2054). SocktainerDNSServer resolves container
/// service names and forwards unknown queries upstream to 1.1.1.1.
///
/// DNS containers are identified by the label `socktainer.role=dns` and
/// named `socktainer-dns-{networkId}`.
actor NetworkDNSManager {
    static let dnsRole = "dns"
    static let roleLabel = "socktainer.role"
    static let networkLabel = "socktainer.network"
    static let containerPrefix = "socktainer-dns-"
    static let dnsPort = 2054

    private let appSupportURL: URL
    private let dnsPort: Int
    private var containerIPs: [String: String] = [:]  // networkId → CoreDNS container IP
    private var pendingCreation: [String: Task<String, Error>] = [:]
    private var log = Logger(label: "socktainer.dns.manager")

    init(appSupportURL: URL, dnsPort: Int = 2054) {
        self.appSupportURL = appSupportURL
        self.dnsPort = dnsPort
    }

    // MARK: - Public API

    /// Returns the IP of the CoreDNS container for `networkId`, creating it lazily.
    /// Concurrent callers for the same network are coalesced — only one container is created.
    func ensureDNSContainer(networkId: String) async throws -> String {
        if let ip = containerIPs[networkId] {
            log.info("[dns-manager] reusing cached CoreDNS at \(ip) for network \(networkId)")
            return ip
        }

        if let pending = pendingCreation[networkId] {
            log.info("[dns-manager] waiting for in-flight CoreDNS creation for network \(networkId)")
            return try await pending.value
        }

        log.info("[dns-manager] creating CoreDNS container for network \(networkId)")
        let appSupportURL = self.appSupportURL
        let dnsPort = self.dnsPort
        let task = Task<String, Error> {
            try await Self.createDNSContainerWork(networkId: networkId, appSupportURL: appSupportURL, dnsPort: dnsPort)
        }
        pendingCreation[networkId] = task

        do {
            let ip = try await task.value
            containerIPs[networkId] = ip
            pendingCreation.removeValue(forKey: networkId)
            log.info("[dns-manager] CoreDNS running at \(ip) for network \(networkId)")
            return ip
        } catch {
            pendingCreation.removeValue(forKey: networkId)
            throw error
        }
    }

    /// Removes the CoreDNS container for `networkId` and clears its cached IP.
    /// Called when a user network is deleted.
    func cleanupDNSContainer(networkId: String) async {
        containerIPs.removeValue(forKey: networkId)
        let containerId = ContainerNameUtility.sanitize(Self.containerPrefix + networkId)
        let client = ContainerClient()
        do {
            guard let snapshot = try? await client.get(id: containerId) else {
                return  // container already gone
            }
            if snapshot.status == .running {
                try? await client.stop(id: containerId)
            }
            // Retry deletion: Apple Container may need a moment to fully release
            // the container from the network after stop. Retry up to 3 times with
            // short gaps rather than a fixed 1s sleep so we stay fast.
            for attempt in 1...3 {
                do {
                    try await client.delete(id: containerId)
                    log.info("[dns-manager] removed DNS container for network \(networkId)")
                    return
                } catch {
                    guard attempt < 3 else {
                        throw error
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        } catch {
            log.warning("[dns-manager] could not remove DNS container \(containerId): \(error)")
        }
    }

    /// Scans for and removes any stale DNS containers left from a previous Socktainer run.
    /// Should be called once at startup.
    func cleanupStaleDNSContainers() async {
        let client = ContainerClient()
        guard let containers = try? await client.list() else { return }
        for container in containers {
            guard container.configuration.labels[Self.roleLabel] == Self.dnsRole else { continue }
            log.info("[dns-manager] cleaning up stale DNS container: \(container.id)")
            if container.status == .running { try? await client.stop(id: container.id) }
            try? await client.delete(id: container.id)
        }
        containerIPs.removeAll()
    }

    // MARK: - Private implementation

    /// Runs outside the actor's executor to avoid deadlock with the Task created in ensureDNSContainer.
    private static func createDNSContainerWork(networkId: String, appSupportURL: URL, dnsPort: Int) async throws -> String {
        let containerClient = ContainerClient()
        // Sanitize to respect Apple Container's 64-char container ID limit
        let containerId = ContainerNameUtility.sanitize(containerPrefix + networkId)

        // Reuse if already running
        if let snapshot = try? await containerClient.get(id: containerId),
            snapshot.status == .running,
            let attachment = snapshot.networks.first(where: { $0.network == networkId })
        {
            return attachment.ipv4Address.address.description
        }

        // Get the network's gateway IP — needed for the CoreDNS Corefile
        let networkResource = try await NetworkClient().get(id: networkId)
        let gatewayIP = networkResource.status.ipv4Gateway.description

        // Write Corefile to a host directory that will be virtiofs-mounted
        let corefileDir = appSupportURL.appendingPathComponent("dns/\(networkId)")
        try FileManager.default.createDirectory(at: corefileDir, withIntermediateDirectories: true)
        let corefileURL = corefileDir.appendingPathComponent("Corefile")
        let corefile = """
            . {
                forward . \(gatewayIP):\(dnsPort)
                cache 10
                errors
            }
            """
        try corefile.write(to: corefileURL, atomically: true, encoding: .utf8)

        // Pull CoreDNS image — arm64 native, no Rosetta needed
        let containerSystemConfig = ContainerSystemConfig()
        let imageRef = try ClientImage.normalizeReference("docker.io/coredns/coredns:latest", containerSystemConfig: containerSystemConfig)
        let platform = Platform.current
        let image = try await ClientImage.fetch(reference: imageRef, platform: platform, containerSystemConfig: containerSystemConfig)
        _ = try await image.getCreateSnapshot(platform: platform)

        let processConfig = ProcessConfiguration(
            executable: "/coredns",
            arguments: ["-conf", "/etc/coredns/Corefile"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: containerId, image: image.description, process: processConfig)
        config.labels = [
            roleLabel: dnsRole,
            networkLabel: networkId,
        ]
        config.mounts = [
            Filesystem.virtiofs(source: corefileDir.path, destination: "/etc/coredns", options: [])
        ]
        config.networks = [
            AttachmentConfiguration(
                network: networkId,
                options: AttachmentOptions(hostname: ContainerNameUtility.sanitize(containerPrefix + networkId))
            )
        ]
        // Point CoreDNS to the vmnet gateway for upstream resolution
        config.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: [gatewayIP],
            domain: nil,
            searchDomains: [],
            options: []
        )

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        // Remove any stale container first
        if let existing = try? await containerClient.get(id: containerId) {
            if existing.status == .running { try? await containerClient.stop(id: containerId) }
            try? await containerClient.delete(id: containerId)
        }

        try await containerClient.create(configuration: config, options: .default, kernel: kernel)
        try await startDNSContainer(id: containerId, client: containerClient)

        let snapshot = try await containerClient.get(id: containerId)
        guard let attachment = snapshot.networks.first(where: { $0.network == networkId }) else {
            throw ContainerizationError(.invalidState, message: "DNS container for \(networkId) has no network attachment")
        }
        return attachment.ipv4Address.address.description
    }

    private static func startDNSContainer(id: String, client: ContainerClient) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        do {
            let process = try await client.bootstrap(id: id, stdio: io.stdio)
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? await client.stop(id: id)
            try? await client.delete(id: id)
            throw ContainerizationError(.internalError, message: "failed to start DNS container: \(error)")
        }
    }
}
