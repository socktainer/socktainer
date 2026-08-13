import ArgumentParser
import BuildInfo
import ContainerResource
import Foundation
import Vapor

// CLI options
struct CLIOptions: ParsableArguments {
    @ArgumentParser.Flag(name: .long, help: "Show version")
    var version: Bool = false

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Check Apple Container compatibility on startup")
    var checkCompatibility: Bool = true

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Create or update the 'socktainer' Docker context on startup")
    var dockerContext: Bool = true

    @ArgumentParser.Option(
        name: .long,
        help:
            "Sync mode for named volumes: fsync (default, honors guest fsyncs for durability), full (fully synchronous writes), nosync (unsafe on host crash; opt-in only). Override per-volume with: docker volume create -o sync=fsync <name>"
    )
    var volumeSync: String = "fsync"
}

// Parse CLI before starting the app
let options = CLIOptions.parseOrExit()

if options.version {
    print("socktainer: \(getBuildVersion()) (git commit: \(getBuildGitCommit()))")
    exit(0)
}

if options.checkCompatibility {
    await AppleContainerVersionCheck.performCompatibilityCheck()
}

// Ignore real CLI args for Vapor: always behave like `socktainer serve`
let executable = CommandLine.arguments.first ?? "socktainer"
let vaporArgs = [executable, "serve"]

// Detect environment and set up logging
var env = try Environment.detect(arguments: vaporArgs)
try LoggingSystem.bootstrap(from: &env)

// Create and configure the Vapor application
let app = try await Application.make(env)
let homeDirectory = SocktainerDirectories.hostHome.path
try prepareUnixSocket(for: app, homeDirectory: homeDirectory)
if options.dockerContext,
    !homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
{
    DockerContextSetup.install(homeDirectory: homeDirectory)
}
app.storage[VolumeSyncModeKey.self] = Filesystem.SyncMode.resolve(from: options.volumeSync)
try await configure(app)

// Start the app
try await app.startup()
do {
    try openUnixSocketToAllUsers(homeDirectory: homeDirectory)
} catch {
    try? await app.asyncShutdown()
    throw error
}
try await app.running?.onStop.get()
