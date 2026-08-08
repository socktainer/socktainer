import ContainerAPIClient
import ContainerNetworkClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import CryptoKit
import Foundation
import Logging
import NIOCore
import NIOPosix
import SystemPackage
import Vapor

struct NetworkRelayManagerKey: StorageKey {
    typealias Value = NetworkRelayManager
}

/// Owns one tiny, volume-free forwarding sidecar per Apple network. Apple
/// transports its Unix listener to the host over vsock; only the sidecar makes
/// connections to guest-network IPs, keeping the Homebrew LaunchAgent outside
/// macOS Local Network Privacy entirely.
actor NetworkRelayManager: NetworkPortRelayProviding {
    static let relayRole = "relay"
    static let artifactLabel = "socktainer.relay.artifact-sha256"
    static let ownerLabel = "socktainer.relay.owner"
    static let containerPrefix = "socktainer-relay-"
    static let guestSocketPath = "/socktainer-relay.sock"
    static let sidecarCPUs = 1
    static let sidecarMemoryInBytes: UInt64 = 256.mib()

    private let appSupportURL: URL
    private let runtimeRoot: URL
    private let ownerID: String
    private let containerSystemConfig: ContainerSystemConfig
    private let imageClient: ClientImageService
    private let eventLoopGroup: any EventLoopGroup
    private var pending: [String: Task<String, Error>] = [:]
    private var cleaning: Set<String> = []
    private let log = Logger(label: "socktainer.relay.manager")

    init(
        appSupportURL: URL,
        runtimeRoot: URL,
        containerSystemConfig: ContainerSystemConfig,
        imageClient: ClientImageService,
        eventLoopGroup: any EventLoopGroup
    ) throws {
        self.appSupportURL = appSupportURL
        self.runtimeRoot = Self.shortRuntimeRoot(seed: runtimeRoot)
        self.ownerID = Self.ownerID(seed: runtimeRoot)
        self.containerSystemConfig = containerSystemConfig
        self.imageClient = imageClient
        self.eventLoopGroup = eventLoopGroup
        try Self.ensurePrivateDirectory(self.runtimeRoot)
    }

    func ensureRelay(networkID: String) async throws -> String {
        guard !cleaning.contains(networkID) else {
            throw ContainerizationError(
                .invalidState,
                message: "relay cleanup is in progress for network \(networkID)"
            )
        }
        if let pending = pending[networkID] { return try await pending.value }
        let appSupportURL = appSupportURL
        let runtimeRoot = runtimeRoot
        let ownerID = ownerID
        let systemConfig = containerSystemConfig
        let imageClient = imageClient
        let eventLoopGroup = eventLoopGroup
        let task = Task {
            try await Self.ensureRelayWork(
                networkID: networkID,
                appSupportURL: appSupportURL,
                runtimeRoot: runtimeRoot,
                containerSystemConfig: systemConfig,
                imageClient: imageClient,
                ownerID: ownerID,
                eventLoopGroup: eventLoopGroup
            )
        }
        pending[networkID] = task
        do {
            let socket = try await task.value
            pending.removeValue(forKey: networkID)
            return socket
        } catch {
            pending.removeValue(forKey: networkID)
            throw error
        }
    }

    func cleanupRelay(networkID: String) async {
        cleaning.insert(networkID)
        defer { cleaning.remove(networkID) }
        if let task = pending.removeValue(forKey: networkID) {
            task.cancel()
            _ = try? await task.value
        }
        let id = Self.containerID(for: networkID, ownerID: ownerID)
        let client = ContainerClient()
        if let snapshot = try? await client.get(id: id) {
            if snapshot.status == .running { try? await client.stop(id: id) }
            try? await client.delete(id: id)
        }
        try? FileManager.default.removeItem(at: Self.socketDirectory(for: networkID, under: runtimeRoot))
    }

    func adoptOrRemoveSidecarsFromPreviousRun() async {
        let client = ContainerClient()
        guard let containers = try? await client.list() else { return }
        for container in containers where Self.isRelay(container) {
            guard Self.isOwnedRelay(container, ownerID: ownerID) else { continue }
            guard let networkID = container.configuration.labels[NetworkDNSManager.networkLabel],
                (try? await NetworkClient().get(id: networkID)) != nil
            else {
                if container.status == .running { try? await client.stop(id: container.id) }
                try? await client.delete(id: container.id)
                continue
            }
            if container.status == .running,
                Self.securePublishedSocket(at: Self.socketPath(for: networkID, under: runtimeRoot)),
                Self.isUsable(
                    container,
                    hostSocket: Self.socketPath(for: networkID, under: runtimeRoot),
                    ownerID: ownerID
                ),
                await Self.relayAcceptsConnections(
                    at: Self.socketPath(for: networkID, under: runtimeRoot),
                    eventLoopGroup: eventLoopGroup
                )
            {
                continue
            }
            if container.status == .running { try? await client.stop(id: container.id) }
            try? await client.delete(id: container.id)
        }
    }

    private static func ensureRelayWork(
        networkID: String,
        appSupportURL: URL,
        runtimeRoot: URL,
        containerSystemConfig: ContainerSystemConfig,
        imageClient: ClientImageService,
        ownerID: String,
        eventLoopGroup: any EventLoopGroup
    ) async throws -> String {
        let directory = socketDirectory(for: networkID, under: runtimeRoot)
        try ensurePrivateDirectory(directory)
        let hostSocket = socketPath(for: networkID, under: runtimeRoot)
        guard hostSocket.utf8.count < 104 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "relay Unix socket path is too long"
            )
        }
        let containerID = containerID(for: networkID, ownerID: ownerID)
        let client = ContainerClient()
        if let existing = try? await client.get(id: containerID),
            existing.status == .running,
            securePublishedSocket(at: hostSocket),
            isUsable(existing, hostSocket: hostSocket, ownerID: ownerID),
            await relayAcceptsConnections(at: hostSocket, eventLoopGroup: eventLoopGroup)
        {
            return hostSocket
        }

        if let existing = try? await client.get(id: containerID) {
            if existing.status == .running { try? await client.stop(id: containerID) }
            try? await client.delete(id: containerID)
        }
        try? FileManager.default.removeItem(atPath: hostSocket)

        let network = try await NetworkClient().get(id: networkID)
        var allowedCIDRs = [network.status.ipv4Subnet.description]
        if let ipv6 = network.status.ipv6Subnet { allowedCIDRs.append(ipv6.description) }
        let image = try await EmbeddedRelayImage.ensure(
            containerSystemConfig: containerSystemConfig,
            appSupportURL: appSupportURL,
            imageClient: imageClient
        )
        _ = try await image.getCreateSnapshot(platform: .current)

        let process = ProcessConfiguration(
            executable: "/socktainer-port-relay",
            arguments: [],
            environment: [
                "SOCKTAINER_RELAY_SOCKET=\(guestSocketPath)",
                "SOCKTAINER_RELAY_CIDRS=\(allowedCIDRs.joined(separator: ","))",
            ],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        var configuration = ContainerConfiguration(
            id: containerID,
            image: image.description,
            process: process
        )
        configuration.resources.cpus = sidecarCPUs
        configuration.resources.memoryInBytes = sidecarMemoryInBytes
        configuration.labels = [
            NetworkDNSManager.roleLabel: relayRole,
            NetworkDNSManager.networkLabel: networkID,
            artifactLabel: SocktainerRelayImage.artifactSHA256,
            ownerLabel: ownerID,
        ]
        configuration.networks = [
            AttachmentConfiguration(
                network: networkID,
                options: AttachmentOptions(hostname: containerID)
            )
        ]
        configuration.publishedSockets = [
            try PublishSocket(
                containerPath: FilePath(guestSocketPath),
                hostPath: FilePath(hostSocket),
                permissions: FilePermissions(rawValue: 0o600)
            )
        ]

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        try await client.create(configuration: configuration, options: .default, kernel: kernel)
        do {
            let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
            defer { try? io.close() }
            let process = try await client.bootstrap(id: containerID, stdio: io.stdio)
            try await process.start()
            try io.closeAfterStart()
            for _ in 0..<100 {
                if securePublishedSocket(at: hostSocket),
                    await relayAcceptsConnections(
                        at: hostSocket,
                        eventLoopGroup: eventLoopGroup
                    )
                {
                    return hostSocket
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw ContainerizationError(
                .invalidState,
                message: "relay socket was not published for network \(networkID)"
            )
        } catch {
            try? await client.stop(id: containerID)
            try? await client.delete(id: containerID)
            try? FileManager.default.removeItem(atPath: hostSocket)
            throw error
        }
    }

    static func isRelay(_ snapshot: ContainerSnapshot) -> Bool {
        snapshot.configuration.labels[NetworkDNSManager.roleLabel] == relayRole
    }

    static func isOwnedRelay(_ snapshot: ContainerSnapshot, ownerID: String) -> Bool {
        isRelay(snapshot) && snapshot.configuration.labels[ownerLabel] == ownerID
    }

    static func isUsable(
        _ snapshot: ContainerSnapshot,
        hostSocket: String,
        ownerID: String
    ) -> Bool {
        guard snapshot.configuration.labels[artifactLabel] == SocktainerRelayImage.artifactSHA256,
            snapshot.configuration.labels[ownerLabel] == ownerID,
            snapshot.configuration.publishedSockets.count == 1
        else { return false }
        let published = snapshot.configuration.publishedSockets[0]
        guard published.containerPath.string == guestSocketPath,
            published.hostPath.string == hostSocket,
            published.permissions?.rawValue == 0o600
        else { return false }
        return privateSocketExists(at: hostSocket)
    }

    private static func privateSocketExists(at path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && (status.st_mode & S_IFMT) == S_IFSOCK
            && status.st_uid == getuid()
            && (status.st_mode & 0o777) == 0o600
    }

    /// Apple Container 1.2.1 records the requested `0600` permission in the
    /// container configuration but can initially publish the host UDS using
    /// the runtime's broader umask. The parent directory is already private;
    /// normalize the owned socket before exposing it to a frontend listener.
    static func securePublishedSocket(at path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFSOCK,
            status.st_uid == getuid(),
            chmod(path, 0o600) == 0
        else { return false }
        return privateSocketExists(at: path)
    }

    private static func relayAcceptsConnections(
        at path: String,
        eventLoopGroup: any EventLoopGroup
    ) async -> Bool {
        do {
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(.seconds(1))
                .connect(unixDomainSocketPath: path)
                .get()
            try await channel.close()
            return true
        } catch {
            return false
        }
    }

    static func containerID(for networkID: String, ownerID: String) -> String {
        let networkDigest = SHA256.hash(data: Data(networkID.utf8))
            .prefix(10).map { String(format: "%02x", $0) }.joined()
        return ContainerNameUtility.sanitize(containerPrefix + ownerID + "-" + networkDigest)
    }

    static func ownerID(seed: URL) -> String {
        SHA256.hash(data: Data(seed.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func socketPath(for networkID: String, under root: URL) -> String {
        socketDirectory(for: networkID, under: root)
            .appendingPathComponent("relay.sock").path
    }

    static func socketDirectory(for networkID: String, under root: URL) -> URL {
        let digest = SHA256.hash(data: Data(networkID.utf8))
            .prefix(10).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    static func shortRuntimeRoot(seed: URL) -> URL {
        let digest = SHA256.hash(data: Data(seed.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL(
            fileURLWithPath: "/tmp/socktainer-relay-\(getuid())-\(digest)",
            isDirectory: true
        )
    }

    static func ensurePrivateDirectory(_ directory: URL) throws {
        var status = stat()
        if lstat(directory.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                status.st_uid == getuid()
            else {
                throw POSIXError(.EACCES)
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
