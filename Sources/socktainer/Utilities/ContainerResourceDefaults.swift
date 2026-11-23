import ContainerAPIClient
import ContainerPersistence
import Logging
import SystemPackage

/// Supplies the `[container]` defaults from Apple Container's own configuration.
///
/// A container created through the Docker API without explicit limits used to be
/// sized by whatever `ContainerConfiguration` happened to default to — a fixed
/// 4 CPUs and 1 GiB — so the configured `[container] cpus`/`memory` had no effect
/// on anything created through socktainer. Only the unset case was affected;
/// `docker run -m 4g --cpus 2` was always honoured.
///
/// The defaults are set in `~/.config/container/config.toml`, for example
///
///     [container]
///     memory = "2gb"
///
/// `container system start` copies that file to
/// `~/Library/Application Support/com.apple.container/config/config.toml`, which is
/// what is read here, layered over the install's `etc/container/config.toml`.
/// (`container system property set` no longer exists; `property` only has `list`.)
/// The values are read the same way the `container` CLI reads them, via
/// `ClientHealthCheck` for the roots and `ConfigurationLoader` for the files.
///
/// Loaded once per process. A changed `[container]` block takes effect only after
/// `container system stop` and `container system start`, and socktainer must then be
/// restarted too, because it keeps the values it loaded.
actor ContainerResourceDefaults {
    typealias Loader = @Sendable () async throws -> ContainerPersistence.ContainerConfig

    static let shared = ContainerResourceDefaults(load: ContainerResourceDefaults.loadFromAppleContainer)

    private let load: Loader
    /// The load every caller awaits. Actors are reentrant at `await`, so callers that arrive
    /// while it is in flight must share it rather than see an empty cache. A successful load
    /// stays; a failed one is cleared so the next container create tries again.
    private var loading: Task<ContainerPersistence.ContainerConfig?, Never>?

    init(load: @escaping Loader) {
        self.load = load
    }

    /// The configured `[container]` defaults, or `nil` if they cannot be read.
    ///
    /// Qualified because socktainer declares its own Docker REST `ContainerConfig`,
    /// which shadows this one inside the module.
    ///
    /// Returns `nil` rather than throwing: failing to read an optional default is
    /// not a reason to fail container creation. The caller then leaves the
    /// configuration untouched, which is the previous behaviour.
    func current(logger: Logger) async -> ContainerPersistence.ContainerConfig? {
        let task = loading ?? startLoad(logger: logger)
        loading = task
        waitingCallers += 1
        let config = await task.value
        waitingCallers -= 1
        // Every caller clears a failed load, not only the one that started it: callers resume
        // in no defined order, and a later caller must not reuse the failed task.
        if config == nil, loading == task {
            loading = nil
        }
        return config
    }

    /// Callers currently awaiting a load. Lets tests wait until callers have joined it.
    private(set) var waitingCallers = 0

    private func startLoad(logger: Logger) -> Task<ContainerPersistence.ContainerConfig?, Never> {
        let load = self.load
        return Task { () -> ContainerPersistence.ContainerConfig? in
            do {
                let config = try await load()
                logger.debug(
                    "[container] defaults loaded: cpus=\(config.cpus) memory=\(config.memory.toUInt64(unit: .bytes)) bytes"
                )
                return config
            } catch {
                logger.warning(
                    "could not read Apple Container's [container] configuration (\(error)); containers created without explicit limits keep the built-in defaults"
                )
                return nil
            }
        }
    }

    /// Reads the `[container]` block the way the `container` CLI does.
    static func loadFromAppleContainer() async throws -> ContainerPersistence.ContainerConfig {
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let appRoot = FilePath(health.appRoot.path(percentEncoded: false))
        let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
        let config: ContainerSystemConfig = try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(in: appRoot, of: .appRoot),
                ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
            ]
        )
        return config.container
    }
}

/// Chooses the resources a container is created with.
///
/// Kept separate from the loading above so the precedence rules are testable
/// without an Apple Container daemon: an explicit value from the request always
/// wins, the configured `[container]` default applies when the request is silent,
/// and `nil` means "leave the configuration alone" — the behaviour before the
/// `[container]` block was consulted at all.
enum ContainerResourceResolution {
    /// Memory in bytes, or `nil` to leave `ContainerConfiguration` untouched.
    static func memoryInBytes(
        requested: Int?,
        configured: ContainerPersistence.ContainerConfig?
    ) -> UInt64? {
        if let requested, requested > 0 {
            return UInt64(requested)
        }
        return configured?.memory.toUInt64(unit: .bytes)
    }

    /// vCPU count, or `nil` to leave `ContainerConfiguration` untouched.
    static func cpus(
        requestedNanoCpus: Int?,
        configured: ContainerPersistence.ContainerConfig?
    ) -> Int? {
        if let requestedNanoCpus, requestedNanoCpus > 0 {
            return max(1, requestedNanoCpus / 1_000_000_000)
        }
        return configured?.cpus
    }
}
