import ContainerAPIClient
import ContainerPersistence
import Logging
import SystemPackage

/// Supplies the `[container]` defaults from Apple Container's own configuration.
///
/// A container created through the Docker API without explicit limits used to be
/// sized by whatever `ContainerConfiguration` happened to default to — a fixed
/// 4 CPUs and 1 GiB — so `container system property set container.cpus`/`memory`
/// had no effect on anything created through socktainer. Only the unset case was
/// affected; `docker run -m 4g --cpus 2` was always honoured.
///
/// The values are read the same way the `container` CLI reads them, via
/// `ClientHealthCheck` for the roots and `ConfigurationLoader` for the files.
///
/// Loaded once per process. Apple Container requires an engine restart for a
/// changed `[container]` block to take effect, and socktainer is restarted with
/// the engine, so a longer-lived cache cannot go stale in practice.
actor ContainerResourceDefaults {
    static let shared = ContainerResourceDefaults()

    private var cached: ContainerPersistence.ContainerConfig?
    private var attempted = false

    /// The configured `[container]` defaults, or `nil` if they cannot be read.
    ///
    /// Qualified because socktainer declares its own Docker REST `ContainerConfig`,
    /// which shadows this one inside the module.
    ///
    /// Returns `nil` rather than throwing: failing to read an optional default is
    /// not a reason to fail container creation. The caller then leaves the
    /// configuration untouched, which is the previous behaviour.
    func current(logger: Logger) async -> ContainerPersistence.ContainerConfig? {
        if let cached {
            return cached
        }
        guard !attempted else {
            return nil
        }
        attempted = true

        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
            let appRoot = FilePath(health.appRoot.path(percentEncoded: false))
            let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
            let config: ContainerSystemConfig = try await ConfigurationLoader.load(
                configurationFiles: [
                    ConfigurationLoader.configurationFile(in: appRoot, of: .appRoot),
                    ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
                ]
            )
            cached = config.container
            logger.debug(
                "[container] defaults loaded: cpus=\(config.container.cpus) memory=\(config.container.memory.toUInt64(unit: .bytes)) bytes"
            )
            return cached
        } catch {
            logger.warning(
                "could not read Apple Container's [container] configuration (\(error)); containers created without explicit limits keep the built-in defaults"
            )
            return nil
        }
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
