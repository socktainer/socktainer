import Darwin
import Foundation

struct LaunchAgentPaths: Sendable, Equatable {
    static let label = "io.github.glassdock.daemon"

    let homeDirectory: URL

    var launchAgent: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    var logDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Logs/GlassDock", isDirectory: true)
    }

    var standardOutputLog: URL { logDirectory.appendingPathComponent("daemon.log") }
    var standardErrorLog: URL { logDirectory.appendingPathComponent("daemon-error.log") }
    var socket: URL { homeDirectory.appendingPathComponent(".glassdock/container.sock") }
    var controlLock: URL { homeDirectory.appendingPathComponent(".glassdock/control.lock") }
    var defaultEngineStateDirectory: URL {
        URL(fileURLWithPath: "/private/var/tmp/glassdock-\(Darwin.getuid())/engine", isDirectory: true)
    }
}

struct CommandResult: Sendable, Equatable {
    let terminationStatus: Int32
}

struct CommandRunner: @unchecked Sendable {
    var run: @Sendable (_ executable: URL, _ arguments: [String]) throws -> CommandResult

    static let live = CommandRunner { executable, arguments in
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return CommandResult(terminationStatus: process.terminationStatus)
    }
}

struct DaemonLifecycle: Sendable {
    let paths: LaunchAgentPaths
    var commandRunner: CommandRunner
    var currentExecutable: URL

    init(
        homeDirectory: URL,
        commandRunner: CommandRunner = .live,
        currentExecutable: URL = URL(fileURLWithPath: CommandLine.arguments[0])
    ) {
        self.paths = LaunchAgentPaths(homeDirectory: homeDirectory)
        self.commandRunner = commandRunner
        self.currentExecutable = currentExecutable
    }

    func diagnostics(managed: Bool, reachable: Bool) -> ControlDiagnostics {
        let ownership: ControlOwnership = managed ? .managedLaunchAgent : (reachable ? .unmanaged : .none)
        return ControlDiagnostics(
            ownership: ownership,
            installation: installationInfo(),
            paths: ControlPaths(
                socket: paths.socket.path,
                logDirectory: paths.logDirectory.path,
                standardOutputLog: paths.standardOutputLog.path,
                standardErrorLog: paths.standardErrorLog.path,
                launchAgent: paths.launchAgent.path,
                controlLock: paths.controlLock.path,
                defaultEngineStateDirectory: paths.defaultEngineStateDirectory.path
            ),
            diskSpace: diskSpaceSignal()
        )
    }

    func installationInfo() -> InstallationInfo {
        guard let executable = try? resolveDaemonExecutable() else {
            return InstallationInfo(kind: .notFound)
        }
        let path = executable.resolvingSymlinksInPath().path
        let kind: InstallationKind
        if path.hasPrefix("/opt/glassdock/") {
            kind = .package
        } else if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            kind = .homebrew
        } else if path.contains("/.build/") {
            kind = .localBuild
        } else {
            kind = .other
        }
        return InstallationInfo(kind: kind, executablePath: path)
    }

    func diskSpaceSignal() -> DiskSpaceSignal? {
        guard
            let values = try? paths.homeDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey,
            ]),
            let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else {
            return nil
        }
        let totalBytes = Int64(total)
        return DiskSpaceSignal(
            volumePath: paths.homeDirectory.path,
            availableBytes: available,
            totalBytes: totalBytes,
            level: DiskSpaceSignal.level(availableBytes: available, totalBytes: totalBytes)
        )
    }

    func isLoaded() -> Bool {
        (try? launchctl(["print", serviceTarget])).map { $0.terminationStatus == 0 } ?? false
    }

    func start() throws {
        let daemon = try resolveDaemonExecutable()
        try installLaunchAgent(daemonExecutable: daemon)
        if isLoaded() {
            let result = try launchctl(["kickstart", "-k", serviceTarget])
            guard result.terminationStatus == 0 else {
                throw ControlError.lifecycle("launchctl kickstart failed with status \(result.terminationStatus)")
            }
        } else {
            let result = try launchctl(["bootstrap", domainTarget, paths.launchAgent.path])
            guard result.terminationStatus == 0 else {
                throw ControlError.lifecycle("launchctl bootstrap failed with status \(result.terminationStatus)")
            }
        }
    }

    func stop() throws {
        guard isLoaded() else { return }
        let result = try launchctl(["bootout", serviceTarget])
        guard result.terminationStatus == 0 else {
            throw ControlError.lifecycle("launchctl bootout failed with status \(result.terminationStatus)")
        }
    }

    func restart() throws {
        if isLoaded() {
            let result = try launchctl(["kickstart", "-k", serviceTarget])
            guard result.terminationStatus == 0 else {
                throw ControlError.lifecycle("launchctl kickstart failed with status \(result.terminationStatus)")
            }
        } else {
            try start()
        }
    }

    func installLaunchAgent(daemonExecutable: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: paths.launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: paths.logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try Self.launchAgentPropertyList(
            daemonExecutable: daemonExecutable,
            paths: paths
        )
        try data.write(to: paths.launchAgent, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.launchAgent.path)
    }

    func resolveDaemonExecutable() throws -> URL {
        let candidates = [
            currentExecutable.deletingLastPathComponent().appendingPathComponent("glassdock"),
            URL(fileURLWithPath: "/opt/glassdock/bin/glassdock"),
            URL(fileURLWithPath: "/opt/homebrew/bin/glassdock"),
            URL(fileURLWithPath: "/usr/local/bin/glassdock"),
        ]
        let fileManager = FileManager.default
        guard
            let result = candidates.first(where: {
                $0.path.hasPrefix("/") && fileManager.isExecutableFile(atPath: $0.path)
            })
        else {
            throw ControlError.daemonExecutableNotFound
        }
        return result.standardizedFileURL
    }

    static func launchAgentPropertyList(daemonExecutable: URL, paths: LaunchAgentPaths) throws -> Data {
        let propertyList: [String: Any] = [
            "Label": LaunchAgentPaths.label,
            "ProgramArguments": [daemonExecutable.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "ThrottleInterval": 5,
            "StandardOutPath": paths.standardOutputLog.path,
            "StandardErrorPath": paths.standardErrorLog.path,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }

    private var domainTarget: String { "gui/\(Darwin.getuid())" }
    private var serviceTarget: String { "\(domainTarget)/\(LaunchAgentPaths.label)" }

    private func launchctl(_ arguments: [String]) throws -> CommandResult {
        do {
            return try commandRunner.run(URL(fileURLWithPath: "/bin/launchctl"), arguments)
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError.lifecycle(error.localizedDescription)
        }
    }
}

enum ControlOperationLock {
    static func withLock<T>(at url: URL, operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw ControlError.lifecycle("cannot open the control operation lock")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw ControlError.lifecycle("cannot acquire the control operation lock")
        }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation()
    }
}

enum DaemonIntent: Sendable {
    case start
    case stop
    case restart
}

enum DaemonSafetyDecision: Sendable, Equatable {
    case proceed
    case noChange(String)
}

enum DaemonSafety {
    static func validate(
        _ intent: DaemonIntent,
        managed: Bool,
        reachable: Bool,
        runningContainers: [ContainerSummary]
    ) throws -> DaemonSafetyDecision {
        switch intent {
        case .start:
            return reachable ? .noChange("Glass Dock is already running.") : .proceed
        case .stop:
            if !managed {
                guard reachable else { return .noChange("Glass Dock is already stopped.") }
                throw ControlError.lifecycle(
                    "The running daemon is not managed by Glass Dock Control. Stop its foreground process instead."
                )
            }
        case .restart:
            if !managed, reachable {
                throw ControlError.lifecycle(
                    "The running daemon is not managed by Glass Dock Control. Stop its foreground process before you start a managed daemon."
                )
            }
        }

        guard runningContainers.isEmpty else {
            let names = runningContainers.prefix(3).map(\.name).joined(separator: ", ")
            let suffix = runningContainers.count > 3 ? ", and \(runningContainers.count - 3) more" : ""
            throw ControlError.lifecycle(
                "Stop the running containers before you control the daemon: \(names)\(suffix)."
            )
        }
        return .proceed
    }
}
