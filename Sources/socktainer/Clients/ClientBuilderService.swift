import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import NIO
import Vapor

struct BuilderPruneRequest: Sendable {
    let all: Bool
    let filters: [String: [String]]
    let keepStorage: Int64?
    let reservedSpace: Int64?
    let maxUsedSpace: Int64?
    let minFreeSpace: Int64?
}

struct BuilderPruneResult: Sendable {
    let deletedCaches: [String]
    let spaceReclaimed: Int64
}

struct BuilderCacheRecord: Sendable {
    let id: String
    let parents: [String]
    let kind: String
    let description: String
    let inUse: Bool
    let shared: Bool
    let size: Int64
    let createdAt: String
    let lastUsedAt: String?
    let usageCount: Int
}

protocol ClientBuilderProtocol: Sendable {
    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws
    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws -> Builder
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord]
}

struct ClientBuilderService: ClientBuilderProtocol {
    private let containerClient = ReconnectingContainerClient(makeClient: { ContainerClient() })
    private let builderContainerId = Builder.builderContainerId
    private let builderPort: UInt32
    private let containerSystemConfig: ContainerSystemConfig

    init(builderPort: UInt32 = 8088, containerSystemConfig: ContainerSystemConfig) {
        self.builderPort = builderPort
        self.containerSystemConfig = containerSystemConfig
    }

    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        let container = try await runningBuilderContainer(logger: logger)

        let command = try BuildctlUtility.pruneCommand(from: request)
        let stdoutText = try await execute(command: command, in: container, actionName: "buildctl prune", logger: logger)

        let entries = BuildctlUtility.parsePruneOutput(stdoutText, logger: logger)
        let deletedIds = entries.compactMap(\.id)
        let reclaimed = entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        return BuilderPruneResult(deletedCaches: deletedIds, spaceReclaimed: reclaimed)
    }

    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        let container = try await runningBuilderContainer(logger: logger)
        let command = BuildctlUtility.duCommand()
        let stdoutText = try await execute(command: command, in: container, actionName: "buildctl du", logger: logger)

        return BuildctlUtility.parseDuOutput(stdoutText, logger: logger).compactMap { record in
            guard let id = record.id else {
                return nil
            }
            return BuilderCacheRecord(
                id: id,
                parents: record.parents ?? [],
                kind: record.recordType ?? "regular",
                description: record.recordDescription ?? "",
                inUse: record.inUse ?? false,
                shared: record.shared ?? false,
                size: record.size ?? 0,
                createdAt: record.createdAt ?? "",
                lastUsedAt: record.lastUsedAt,
                usageCount: record.usageCount ?? 0
            )
        }
    }

    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws {
        _ = try await runningBuilderContainer(logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket()
                try? socket.close()
                return
            } catch {
                lastError = error
                logger.debug("Builder reachability check failed: \(error)")
            }

            try await Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability")
    }

    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws -> Builder {
        _ = try await runningBuilderContainer(logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket()
                let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                let builder = try await Builder(socket: socket, group: group, logger: logger)
                do {
                    _ = try await builder.info()
                    return builder
                } catch {
                    try? await group.shutdownGracefully()
                    throw error
                }
            } catch {
                lastError = error
                logger.debug("Builder connection attempt failed: \(error)")
            }

            try await Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder")
    }

    private func dialBuilderSocket() async throws -> FileHandle {
        let container = try await runningBuilderContainer(logger: nil)
        return try await containerClient.withClient { try await $0.dial(id: container.id, port: builderPort) }
    }

    private func runningBuilderContainer(logger: Logger?) async throws -> ContainerSnapshot {
        do {
            let container = try await containerClient.withClient { try await $0.get(id: builderContainerId) }
            if container.status == .running {
                return container
            }
            logger?.info("Builder container is \(container.status), starting it")
        } catch let error as ContainerizationError where error.code == .notFound {
            logger?.info("Builder container not found, creating a new builder instance")
        }
        return try await startBuilder(logger: logger)
    }

    /// Starts the builder with apple/container's own `Builder.start`, which `container build`
    /// uses too: it creates the BuildKit container if needed, restarts a stopped one, and
    /// recreates one whose image or resources no longer match the system configuration.
    private func startBuilder(logger: Logger?) async throws -> ContainerSnapshot {
        // Builder.start fetches over HTTPS only. Fetch first with the scheme the reference
        // calls for, so a builder image on a local insecure registry still works; Builder.start
        // then finds the image already in the store. Best effort: a stopped builder that still
        // matches restarts without its image, which may have been deleted, so a failure here is
        // only fatal if Builder.start goes on to need the image.
        let builderImage = containerSystemConfig.build.image
        do {
            _ = try await ClientImage.fetch(
                reference: builderImage,
                platform: Platform(arch: "arm64", os: "linux", variant: "v8"),
                scheme: RegistryScheme.scheme(forReference: builderImage, internalDnsDomain: containerSystemConfig.dns.domain),
                containerSystemConfig: containerSystemConfig
            )
        } catch {
            logger?.warning("Could not fetch builder image \(builderImage) ahead of starting the builder: \(error)")
        }

        try await Builder.start(
            cpus: nil,
            memory: nil,
            log: logger ?? Logger(label: "socktainer.builder"),
            progressUpdate: { _ in },
            containerSystemConfig: containerSystemConfig
        )
        return try await containerClient.withClient { try await $0.get(id: builderContainerId) }
    }

    private func execute(command: BuildctlUtility.Command, in container: ContainerSnapshot, actionName: String, logger: Logger) async throws -> String {
        var processConfig = container.configuration.initProcess
        processConfig.executable = command.executable
        processConfig.arguments = command.arguments
        processConfig.terminal = false

        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw ContainerizationError(.internalError, message: "Failed to create I/O pipes")
        }
        let process: ClientProcess
        let processConfigToSend = processConfig
        do {
            process = try await containerClient.withClient {
                try await $0.createProcess(
                    containerId: container.id,
                    processId: UUID().uuidString.lowercased(),
                    configuration: processConfigToSend,
                    stdio: pipes.stdioArray
                )
            }
        } catch {
            pipes.closeAll()
            throw error
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw error
        }
        let (exitCode, stdoutData, stderrData) = try await pipes.collectOutput {
            try await process.wait()
        }
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderrText.isEmpty {
            logger.error("\(actionName) stderr:\n\(stderrText)")
        }

        guard exitCode == 0 else {
            let details = stderrText.isEmpty ? stdoutText : stderrText
            throw ContainerizationError(.unknown, message: "\(actionName) failed with exit code \(exitCode): \(details)")
        }

        return stdoutText
    }

}
