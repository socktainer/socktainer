import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Vapor

struct InfoRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let imageClient: ClientImageProtocol
    let configLoader: @Sendable () async throws -> ContainerSystemConfig
    let systemHealthProvider: @Sendable () async throws -> (dockerRootDir: String, serverVersion: String)
    let kernelNameProvider: @Sendable () async throws -> String

    init(
        containerClient: ClientContainerProtocol,
        imageClient: ClientImageProtocol,
        configLoader: @Sendable @escaping () async throws -> ContainerSystemConfig = {
            try await ConfigurationLoader.load()
        },
        systemHealthProvider: @Sendable @escaping () async throws -> (dockerRootDir: String, serverVersion: String) = {
            let health = try await ClientHealthCheck.ping()
            return (health.appRoot.path, health.apiServerVersion)
        },
        kernelNameProvider: @Sendable @escaping () async throws -> String = {
            try await getLinuxDefaultKernelName()
        }
    ) {
        self.containerClient = containerClient
        self.imageClient = imageClient
        self.configLoader = configLoader
        self.systemHealthProvider = systemHealthProvider
        self.kernelNameProvider = kernelNameProvider
    }

    func boot(routes: RoutesBuilder) throws {
        let containerClient = self.containerClient
        let imageClient = self.imageClient
        let configLoader = self.configLoader
        let systemHealthProvider = self.systemHealthProvider
        let kernelNameProvider = self.kernelNameProvider
        try routes.registerVersionedRoute(.GET, pattern: "/info") { req in
            try await InfoRoute.handle(
                req,
                containerClient: containerClient,
                imageClient: imageClient,
                configLoader: configLoader,
                systemHealthProvider: systemHealthProvider,
                kernelNameProvider: kernelNameProvider
            )
        }
    }

    private static func handle(
        _ req: Request,
        containerClient: ClientContainerProtocol,
        imageClient: ClientImageProtocol,
        configLoader: @Sendable () async throws -> ContainerSystemConfig,
        systemHealthProvider: @Sendable () async throws -> (dockerRootDir: String, serverVersion: String),
        kernelNameProvider: @Sendable () async throws -> String
    ) async throws -> Response {
        do {
            let allContainers = try await containerClient.list(showAll: true, filters: [:])

            // Falls back to defaults if config.toml is missing or malformed — non-fatal for /info
            let systemConfig = try await loadSystemConfig(using: configLoader, logger: req.logger)

            let health = try await systemHealthProvider()

            let info = SystemInfo(
                Containers: allContainers.count,
                ContainersRunning: allContainers.filter { $0.status == RuntimeStatus.running }.count,
                // Apple container doesn't support pausing containers
                ContainersPaused: 0,
                ContainersStopped: allContainers.filter { $0.status == RuntimeStatus.stopped }.count,
                Images: try await imageClient.list().count,
                DockerRootDir: health.dockerRootDir,
                Debug: isDebug(),
                KernelVersion: try await kernelNameProvider(),
                OSVersion: currentPlatform().osVersion ?? nil,
                OSType: currentPlatform().os,
                Architecture: currentPlatform().architecture,
                NCPU: hostCPUCoreCount(),
                MemTotal: Int64(hostPhysicalMemory()),
                HttpProxy: ProcessInfo.processInfo.environment["HTTP_PROXY"] ?? nil,
                HttpsProxy: ProcessInfo.processInfo.environment["HTTPS_PROXY"] ?? nil,
                NoProxy: ProcessInfo.processInfo.environment["NO_PROXY"] ?? nil,
                Name: hostName(),
                Labels: systemPropertyLabels(config: systemConfig),
                ExperimentalBuild: true,
                ServerVersion: health.serverVersion,
                ProductLicense: "socktainer [Apache License 2.0], Apple container [Apache License 2.0]",
                SystemTime: currentTime(),
                Warnings: [
                    "WARNING: Apple container system info may differ",
                    "NOTE: socktainer is still under active development and considered experimental!",
                ],
            )
            return try await info.encodeResponse(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.error("InfoRoute handler failed: \(error)")
            let response = Response(status: .internalServerError)
            response.headers.add(name: .contentType, value: "application/json")
            response.body = .init(string: "{\"message\": \"Failed to generate system information\"}\n")
            return response
        }
    }

    /// Loads the system config, falling back to defaults when `config.toml` is missing or malformed.
    /// Cancellation is rethrown so request cancellation is not masked by the fallback.
    static func loadSystemConfig(
        using configLoader: @Sendable () async throws -> ContainerSystemConfig,
        logger: Logger
    ) async throws -> ContainerSystemConfig {
        do {
            return try await configLoader()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Failed to load system config, using defaults: \(error)")
            return ContainerSystemConfig()
        }
    }

    static func systemPropertyLabels(config: ContainerSystemConfig) -> [String] {
        [
            "build.rosetta=\(config.build.rosetta)",
            "dns.domain=\(config.dns.domain ?? "*undefined*")",
            "image.builder=\(config.build.image)",
            "image.init=\(config.vminit.image)",
            "kernel.binaryPath=\(config.kernel.binaryPath)",
            "kernel.url=\(config.kernel.url.absoluteString)",
            "network.subnet=\(config.network.subnet?.description ?? "*undefined*")",
            "registry.domain=\(config.registry.domain)",
        ]
    }
}
