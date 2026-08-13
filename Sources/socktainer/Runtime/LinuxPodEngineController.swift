import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import NIOCore
import Virtualization

private final class EngineLogWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.close()
    }
}

@available(macOS 26.0, *)
/// Owns one direct Apple VZ pod whose only process is the Socktainer guest
/// engine. Docker workloads remain containerd tasks inside that engine.
@available(macOS 26.0, *)
actor LinuxPodEngineController: EngineMachineControlling {
    private static let engineContainerID = "engine"

    private let artifact: EngineGuestImageArtifact
    private let eventLoopGroup: any EventLoopGroup
    private let logger: Logger
    private let stateDirectory: URL
    private var pod: LinuxPod?
    private var interface: (any Containerization.Interface)?
    private var running = false

    init(
        artifact: EngineGuestImageArtifact,
        eventLoopGroup: any EventLoopGroup,
        logger: Logger = Logger(label: "socktainer.engine.vz")
    ) {
        self.artifact = artifact
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.stateDirectory =
            ProcessInfo.processInfo.environment[
                "SOCKTAINER_ENGINE_STATE_DIRECTORY"
            ].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SocktainerDirectories.hostHome
            .appendingPathComponent(
                "Library/Application Support/Socktainer/engine",
                isDirectory: true
            )
    }

    func inspect(id: String) async throws -> EngineMachine? {
        guard id == PersistentEngine.machineID, pod != nil else { return nil }
        return EngineMachine(
            id: id,
            containerID: Self.engineContainerID,
            ipAddress: running ? interface?.ipv4Address.address.description ?? "" : "",
            running: running
        )
    }

    func provision(id: String) async throws {
        guard pod == nil else { return }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let dataConfiguration = try DirectVZEngineConfiguration(
            id: id,
            stateDirectory: stateDirectory,
            bindRoot: SocktainerDirectories.hostHome,
            dataDiskSize: 1024 * 1024 * 1024,
            cpus: Self.configuredCPUCount(),
            memoryInBytes: Self.configuredMemoryInBytes()
        )
        try DirectVZEngineController.prepareDataDisk(dataConfiguration)

        let rootfs = try await guestRootfs()
        let guestLog = try EngineLogWriter(url: stateDirectory.appendingPathComponent("guest.log"))
        let systemConfiguration = try await ConfigurationLoader.load()
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        let initImage = try await ClientImage.fetch(
            reference: systemConfiguration.vminit.image,
            platform: .current,
            containerSystemConfig: systemConfiguration
        )
        let initFilesystem = try await initImage.getCreateSnapshot(platform: .current)
        let initialMount = try Self.blockMount(initFilesystem, readOnly: true)
        let manager = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initialMount,
            group: eventLoopGroup,
            logger: logger
        )
        let network = try NativeVmnetNetwork()
        let interface = network.interface
        let pod = try LinuxPod(id, vmm: manager, logger: logger) { configuration in
            configuration.cpus = dataConfiguration.cpus
            configuration.memoryInBytes = dataConfiguration.memoryInBytes
            configuration.interfaces = [interface]
            configuration.dns = DNS(nameservers: ["1.1.1.1", "8.8.8.8"])
            configuration.volumes = [
                .init(name: "containerd", source: .diskImage(path: dataConfiguration.dataDisk), format: "ext4")
            ]
        }
        try await pod.addContainer(Self.engineContainerID, rootfs: rootfs) { configuration in
            let home = SocktainerDirectories.hostHome.path
            configuration.process.arguments = [
                "/sbin/init",
                "--bind-source",
                home,
                "--bind-cache",
                "/run/socktainer-bind-cache",
            ]
            configuration.process.stdout = guestLog
            configuration.process.stderr = guestLog
            configuration.process.capabilities = .allCapabilities
            configuration.maskedPaths = []
            configuration.readonlyPaths = []
            configuration.mounts.append(
                .sharedMount(name: "containerd", destination: "/var/lib/containerd", options: ["discard"])
            )
            configuration.mounts.append(
                .share(
                    source: home,
                    destination: home,
                    options: ["rw"]
                )
            )
        }
        self.interface = interface
        self.pod = pod
    }

    func boot(id: String) async throws -> EngineMachine {
        guard let pod, let interface else {
            throw PersistentEngineError.invalidMachineSnapshot("engine pod is not provisioned")
        }
        if !running {
            try await pod.create()
            try await pod.startContainer(Self.engineContainerID)
            running = true
        }
        return EngineMachine(
            id: id,
            containerID: Self.engineContainerID,
            ipAddress: interface.ipv4Address.address.description,
            running: true
        )
    }

    func dial(containerID: String, port: UInt32) async throws -> FileHandle {
        guard containerID == Self.engineContainerID, let pod, running else {
            throw PersistentEngineError.invalidMachineSnapshot("engine pod is not running")
        }
        return try await pod.dialVsock(port: port)
    }

    func stop(id: String) async throws {
        guard id == PersistentEngine.machineID, let pod, running else { return }
        try await pod.stop()
        self.pod = nil
        interface = nil
        running = false
    }

    private func guestRootfs() async throws -> Containerization.Mount {
        let loaded = try await ClientImage.load(from: artifact.url.path)
        guard let image = loaded.images.first else {
            throw EngineMachineProvisioningError.guestImageEmpty
        }
        var filesystem = try await image.getCreateSnapshot(platform: .current)
        filesystem.options.removeAll(where: { $0 == "ro" })
        return try Self.blockMount(filesystem, readOnly: false)
    }

    private static func configuredCPUCount() -> Int {
        guard let value = ProcessInfo.processInfo.environment["SOCKTAINER_ENGINE_CPUS"],
            let count = Int(value),
            (1...System.coreCount).contains(count)
        else {
            return 6
        }
        return count
    }

    private static func configuredMemoryInBytes() -> UInt64 {
        guard let value = ProcessInfo.processInfo.environment["SOCKTAINER_ENGINE_MEMORY_MIB"],
            let mebibytes = UInt64(value),
            (96...65_536).contains(mebibytes)
        else {
            // The coherent bind cache needs enough guest memory to retain the
            // 512 MiB benchmark working set. VZ maps this memory lazily, so the
            // idle host footprint remains based on resident pages.
            return 1_024 * 1024 * 1024
        }
        return mebibytes * 1024 * 1024
    }

    private static func blockMount(_ filesystem: Filesystem, readOnly: Bool) throws -> Containerization.Mount {
        let options = readOnly ? ["ro"] : filesystem.options
        switch filesystem.type {
        case .block(let format, _, _), .volume(_, let format, _, _):
            return .block(
                format: format,
                source: filesystem.source,
                destination: "/",
                options: options,
                runtimeOptions: [
                    "vzDiskImageCachingMode=cached",
                    "vzDiskImageSynchronizationMode=fsync",
                ]
            )
        case .virtiofs, .tmpfs:
            throw DirectVZEngineControllerError.unsupportedInitialFilesystem
        }
    }
}
