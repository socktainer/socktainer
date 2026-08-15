import Foundation

public enum DaemonState: String, Codable, Sendable {
    case running
    case starting
    case stopped
    case unhealthy
}

public enum ComponentHealth: String, Codable, Sendable {
    case healthy
    case unhealthy
    case starting
}

public struct DaemonStatus: Codable, Sendable, Equatable {
    public let state: DaemonState
    public let healthy: Bool
    public let managed: Bool
    public let socketPath: String
    public let socketExists: Bool
    public let socketReachable: Bool
    public let virtualMachineHealth: ComponentHealth?
    public let version: String?
    public let apiVersion: String?
    public let gitCommit: String?
    public let buildTime: String?
    public let message: String?

    public init(
        state: DaemonState,
        healthy: Bool,
        managed: Bool,
        socketPath: String,
        socketExists: Bool,
        socketReachable: Bool,
        virtualMachineHealth: ComponentHealth? = nil,
        version: String? = nil,
        apiVersion: String? = nil,
        gitCommit: String? = nil,
        buildTime: String? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.healthy = healthy
        self.managed = managed
        self.socketPath = socketPath
        self.socketExists = socketExists
        self.socketReachable = socketReachable
        self.virtualMachineHealth = virtualMachineHealth
        self.version = version
        self.apiVersion = apiVersion
        self.gitCommit = gitCommit
        self.buildTime = buildTime
        self.message = message
    }
}

public struct ContainerSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String

    public init(id: String, name: String, image: String, state: String, status: String) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
    }

    public var isRunning: Bool { state == "running" }
}

public enum ControlOwnership: String, Codable, Sendable {
    case managedLaunchAgent = "managed-launch-agent"
    case unmanaged
    case none
}

public enum InstallationKind: String, Codable, Sendable {
    case package
    case homebrew
    case localBuild = "local-build"
    case other
    case notFound = "not-found"
}

public struct InstallationInfo: Codable, Sendable, Equatable {
    public let kind: InstallationKind
    public let executablePath: String?

    public init(kind: InstallationKind, executablePath: String? = nil) {
        self.kind = kind
        self.executablePath = executablePath
    }
}

public struct ControlPaths: Codable, Sendable, Equatable {
    public let socket: String
    public let logDirectory: String
    public let standardOutputLog: String
    public let standardErrorLog: String
    public let launchAgent: String
    public let controlLock: String
    public let defaultEngineStateDirectory: String

    public init(
        socket: String,
        logDirectory: String,
        standardOutputLog: String,
        standardErrorLog: String,
        launchAgent: String,
        controlLock: String,
        defaultEngineStateDirectory: String
    ) {
        self.socket = socket
        self.logDirectory = logDirectory
        self.standardOutputLog = standardOutputLog
        self.standardErrorLog = standardErrorLog
        self.launchAgent = launchAgent
        self.controlLock = controlLock
        self.defaultEngineStateDirectory = defaultEngineStateDirectory
    }
}

public enum DiskSpaceLevel: String, Codable, Sendable {
    case normal
    case low
    case critical
}

public struct DiskSpaceSignal: Codable, Sendable, Equatable {
    public let volumePath: String
    public let availableBytes: Int64
    public let totalBytes: Int64
    public let level: DiskSpaceLevel

    public init(
        volumePath: String,
        availableBytes: Int64,
        totalBytes: Int64,
        level: DiskSpaceLevel
    ) {
        self.volumePath = volumePath
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.level = level
    }

    public static func level(availableBytes: Int64, totalBytes: Int64) -> DiskSpaceLevel {
        let ratio = totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 1
        if availableBytes <= 2_000_000_000 || ratio <= 0.02 {
            return .critical
        }
        if availableBytes <= 10_000_000_000 || ratio <= 0.10 {
            return .low
        }
        return .normal
    }
}

public struct ControlDiagnostics: Codable, Sendable, Equatable {
    public let ownership: ControlOwnership
    public let installation: InstallationInfo
    public let paths: ControlPaths
    public let diskSpace: DiskSpaceSignal?

    public init(
        ownership: ControlOwnership,
        installation: InstallationInfo,
        paths: ControlPaths,
        diskSpace: DiskSpaceSignal? = nil
    ) {
        self.ownership = ownership
        self.installation = installation
        self.paths = paths
        self.diskSpace = diskSpace
    }
}

public struct ControlSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let capturedAt: Date
    public let daemon: DaemonStatus
    public let containers: [ContainerSummary]
    public let diagnostics: ControlDiagnostics

    public init(
        schemaVersion: Int = currentSchemaVersion,
        capturedAt: Date = Date(),
        daemon: DaemonStatus,
        containers: [ContainerSummary],
        diagnostics: ControlDiagnostics
    ) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.daemon = daemon
        self.containers = containers
        self.diagnostics = diagnostics
    }
}

public enum ControlAction: Sendable, Equatable {
    case startDaemon
    case stopDaemon
    case restartDaemon
    case startContainer(String)
    case stopContainer(String)
}

public struct ActionResult: Codable, Sendable, Equatable {
    public let succeeded: Bool
    public let message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

public struct LogOutput: Codable, Sendable, Equatable {
    public let source: String
    public let text: String
    public let truncated: Bool
    public let byteCount: Int

    public init(source: String, text: String, truncated: Bool = false, byteCount: Int? = nil) {
        self.source = source
        self.text = text
        self.truncated = truncated
        self.byteCount = byteCount ?? text.utf8.count
    }
}

public struct SupportReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let snapshot: ControlSnapshot
    public let recentLogs: [LogOutput]
    public let text: String

    public init(
        schemaVersion: Int = ControlSnapshot.currentSchemaVersion,
        generatedAt: Date = Date(),
        snapshot: ControlSnapshot,
        recentLogs: [LogOutput]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.snapshot = snapshot
        self.recentLogs = recentLogs
        self.text = Self.makeText(generatedAt: generatedAt, snapshot: snapshot, recentLogs: recentLogs)
    }

    private static func makeText(
        generatedAt: Date,
        snapshot: ControlSnapshot,
        recentLogs: [LogOutput]
    ) -> String {
        let daemon = snapshot.daemon
        let diagnostics = snapshot.diagnostics
        let date = ISO8601DateFormatter().string(from: generatedAt)
        var lines = [
            "Glass Dock Support Report",
            "Generated: \(date)",
            "Contract schema: \(snapshot.schemaVersion)",
            "",
            "Status",
            "Daemon state: \(daemon.state.rawValue)",
            "Daemon health: \(daemon.healthy ? "healthy" : "unavailable")",
            "VM health: \(daemon.virtualMachineHealth?.rawValue ?? "not reported")",
            "Socket exists: \(daemon.socketExists ? "yes" : "no")",
            "Socket reachable: \(daemon.socketReachable ? "yes" : "no")",
            "Socket path: \(daemon.socketPath)",
            "Version: \(daemon.version ?? "not reported")",
            "Docker API: \(daemon.apiVersion ?? "not reported")",
            "Git commit: \(daemon.gitCommit ?? "not reported")",
            "Build time: \(daemon.buildTime ?? "not reported")",
            "Control ownership: \(diagnostics.ownership.rawValue)",
            "Installation: \(diagnostics.installation.kind.rawValue)",
            "Discovered executable: \(diagnostics.installation.executablePath ?? "not found")",
            "Containers: \(snapshot.containers.filter(\.isRunning).count) running, \(snapshot.containers.count) total",
        ]
        if let message = daemon.message {
            lines.append("Detail: \(message)")
        }
        if let disk = diagnostics.diskSpace {
            lines.append("Disk space: \(disk.level.rawValue) (\(disk.availableBytes) of \(disk.totalBytes) bytes available at \(disk.volumePath))")
        } else {
            lines.append("Disk space: not available")
        }
        lines.append(contentsOf: [
            "",
            "Paths",
            "Logs: \(diagnostics.paths.logDirectory)",
            "Standard output: \(diagnostics.paths.standardOutputLog)",
            "Standard error: \(diagnostics.paths.standardErrorLog)",
            "LaunchAgent: \(diagnostics.paths.launchAgent)",
            "Control lock: \(diagnostics.paths.controlLock)",
            "Default engine state: \(diagnostics.paths.defaultEngineStateDirectory)",
            "",
            "Recent managed daemon logs",
        ])
        if recentLogs.isEmpty {
            lines.append("No managed daemon logs are available.")
        } else {
            for log in recentLogs {
                let suffix = log.truncated ? "; truncated" : ""
                lines.append("== \(log.source) (last \(log.byteCount) bytes\(suffix)) ==")
                lines.append(log.text)
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ControlError: LocalizedError, Sendable, Equatable {
    case daemonExecutableNotFound
    case invalidSocketPath(String)
    case socket(String)
    case malformedResponse(String)
    case requestFailed(status: Int, message: String)
    case lifecycle(String)
    case invalidContainerIdentifier

    public var errorDescription: String? {
        switch self {
        case .daemonExecutableNotFound:
            return "The Glass Dock daemon executable was not found."
        case .invalidSocketPath(let path):
            return "The Unix socket path is invalid: \(path)"
        case .socket(let message):
            return "Cannot connect to the Glass Dock socket: \(message)"
        case .malformedResponse(let message):
            return "Glass Dock returned an invalid response: \(message)"
        case .requestFailed(let status, let message):
            return "Glass Dock request failed with status \(status): \(message)"
        case .lifecycle(let message):
            return "Cannot control the Glass Dock daemon: \(message)"
        case .invalidContainerIdentifier:
            return "The container identifier is empty or invalid."
        }
    }
}
