import ArgumentParser
import BuildInfo
import ContainerResource
import Foundation
import Vapor

// CLI options
struct CLIOptions: ParsableArguments {
    static let defaultCPUCount = RuntimeMachineConfiguration.defaultCPUCount
    static let defaultMemoryMiB = RuntimeMachineConfiguration.defaultMemoryBytes / (1024 * 1024)

    @ArgumentParser.Flag(name: .long, help: "Show version")
    var version: Bool = false

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Create or update the 'glassdock' Docker context on startup")
    var dockerContext: Bool = true

    @ArgumentParser.Option(
        name: .long,
        help:
            "Sync mode for named volumes: fsync (default, honors guest fsyncs for durability), full (fully synchronous writes), nosync (unsafe on host crash; opt-in only). Override per-volume with: docker volume create -o sync=fsync <name>"
    )
    var volumeSync: String = "fsync"

    @ArgumentParser.Option(
        name: .long,
        help: "Number of virtual CPUs for the runtime VM (1 through 64)"
    )
    var cpus: Int = Self.defaultCPUCount

    @ArgumentParser.Option(
        name: .customLong("memory-mib"),
        help: "Runtime VM memory in MiB (96 through 65536)"
    )
    var memoryMiB: UInt64 = Self.defaultMemoryMiB

    func validate() throws {
        guard (1...RuntimeMachineConfiguration.maximumCPUCount).contains(cpus) else {
            throw ValidationError(
                "--cpus must be between 1 and \(RuntimeMachineConfiguration.maximumCPUCount)"
            )
        }
        let minimumMemoryMiB = RuntimeMachineConfiguration.minimumMemoryBytes / (1024 * 1024)
        let maximumMemoryMiB = RuntimeMachineConfiguration.maximumMemoryBytes / (1024 * 1024)
        guard (minimumMemoryMiB...maximumMemoryMiB).contains(memoryMiB) else {
            throw ValidationError(
                "--memory-mib must be between \(minimumMemoryMiB) and \(maximumMemoryMiB)"
            )
        }
    }
}

// Parse CLI before starting the app
let options = CLIOptions.parseOrExit()

if options.version {
    print("glassdock: \(getBuildVersion()) (git commit: \(getBuildGitCommit()))")
    exit(0)
}

// Ignore real CLI args for Vapor: always behave like `glassdock serve`
let executable = CommandLine.arguments.first ?? "glassdock"
let vaporArgs = [executable, "serve"]

// Detect environment and set up logging
var env = try Environment.detect(arguments: vaporArgs)
try LoggingSystem.bootstrap(from: &env)

// Create and configure the Vapor application
let app = try await Application.make(env)
let homeDirectory = GlassDockDirectories.hostHome.path
let engineStateLock = try EngineStateLock.acquire(
    directory: GlassDockDirectories.engineStateDirectory
)
app.storage[EngineStateLockKey.self] = engineStateLock
try prepareUnixSocket(for: app, homeDirectory: homeDirectory)
if options.dockerContext,
    !homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
{
    DockerContextSetup.install(homeDirectory: homeDirectory)
}
app.storage[VolumeSyncModeKey.self] = Filesystem.SyncMode.resolve(from: options.volumeSync)
try await configure(
    app,
    cpuCount: options.cpus,
    memoryBytes: options.memoryMiB * 1024 * 1024
)

// Start the app
try await app.startup()
do {
    try openUnixSocketToAllUsers(homeDirectory: homeDirectory)
} catch {
    try? await app.asyncShutdown()
    throw error
}
try await app.running?.onStop.get()
try await app.asyncShutdown()
