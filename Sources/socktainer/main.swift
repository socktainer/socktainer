import ArgumentParser
import BuildInfo
import Foundation
import Vapor

// CLI options
struct CLIOptions: ParsableArguments {
    @ArgumentParser.Flag(name: .long, help: "Show version")
    var version: Bool = false
}

// Parse CLI before starting the app
let options = CLIOptions.parseOrExit()

if options.version {
    print("socktainer: \(getBuildVersion()) (git commit: \(getBuildGitCommit()))")
    exit(0)
}
// Detect environment and set up logging
var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

// Create and configure the Vapor application
let app = try await Application.make(env)
try prepareUnixSocket(for: app, homeDirectory: ProcessInfo.processInfo.environment["HOME"])
try await configure(app)

// Start the app
try await app.execute()
