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

/// Manages one DNS forwarder sidecar container per user-created network.
///
/// Each forwarder is the embedded `socktainer-dns` binary (static Rust, ~388 KB,
/// bundled as a Swift Package resource). It proxies DNS queries from containers
/// to SocktainerDNSServer on the macOS host via the network gateway, without
/// pulling anything from the internet at runtime.
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
    private let containerSystemConfig: ContainerSystemConfig
    private var containerIPs: [String: String] = [:]  // networkId → DNS forwarder container IP
    private var pendingCreation: [String: Task<String, Error>] = [:]
    private var log = Logger(label: "socktainer.dns.manager")

    init(appSupportURL: URL, dnsPort: Int = 2054, containerSystemConfig: ContainerSystemConfig) {
        self.appSupportURL = appSupportURL
        self.dnsPort = dnsPort
        self.containerSystemConfig = containerSystemConfig
    }

    // MARK: - Public API

    /// Returns the IP of the DNS forwarder container for `networkId`, creating it lazily.
    /// Concurrent callers for the same network are coalesced — only one container is created.
    func ensureDNSContainer(networkId: String) async throws -> String {
        if let ip = containerIPs[networkId] {
            log.info("[dns-manager] reusing cached DNS forwarder at \(ip) for network \(networkId)")
            return ip
        }

        if let pending = pendingCreation[networkId] {
            log.info("[dns-manager] waiting for in-flight DNS forwarder creation for network \(networkId)")
            return try await pending.value
        }

        log.info("[dns-manager] creating DNS forwarder container for network \(networkId)")
        let appSupportURL = self.appSupportURL
        let dnsPort = self.dnsPort
        let containerSystemConfig = self.containerSystemConfig
        let task = Task<String, Error> {
            try await Self.createDNSContainerWork(networkId: networkId, appSupportURL: appSupportURL, dnsPort: dnsPort, containerSystemConfig: containerSystemConfig)
        }
        pendingCreation[networkId] = task

        do {
            let ip = try await task.value
            containerIPs[networkId] = ip
            pendingCreation.removeValue(forKey: networkId)
            log.info("[dns-manager] DNS forwarder running at \(ip) for network \(networkId)")
            return ip
        } catch {
            pendingCreation.removeValue(forKey: networkId)
            throw error
        }
    }

    /// Removes the DNS forwarder container for `networkId` and clears its cached IP.
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
                    let corefileDir = appSupportURL.appendingPathComponent("dns/\(networkId)")
                    try? FileManager.default.removeItem(at: corefileDir)
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
    private static func createDNSContainerWork(networkId: String, appSupportURL: URL, dnsPort: Int, containerSystemConfig: ContainerSystemConfig) async throws -> String {
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

        // Get the network's gateway IP — passed to the forwarder as DNS_UPSTREAM
        let networkResource = try await NetworkClient().get(id: networkId)
        let gatewayIP = networkResource.status.ipv4Gateway.description

        // Ensure the embedded DNS forwarder image is available (imports from bundle on first use)
        try await EmbeddedDNSImage.ensure(
            containerSystemConfig: containerSystemConfig,
            appSupportURL: appSupportURL
        )

        let platform = Platform.current
        let image = try await ClientImage.fetch(
            reference: EmbeddedDNSImage.tag,
            platform: platform,
            containerSystemConfig: containerSystemConfig
        )
        _ = try await image.getCreateSnapshot(platform: platform)

        let processConfig = ProcessConfiguration(
            executable: "/dns-forwarder",
            arguments: [],
            environment: ["DNS_UPSTREAM=\(gatewayIP):\(dnsPort)"],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: containerId, image: image.description, process: processConfig)
        config.labels = [
            roleLabel: dnsRole,
            networkLabel: networkId,
        ]
        config.networks = [
            AttachmentConfiguration(
                network: networkId,
                options: AttachmentOptions(hostname: ContainerNameUtility.sanitize(containerPrefix + networkId))
            )
        ]
        // Point DNS forwarder to the vmnet gateway for upstream resolution
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
