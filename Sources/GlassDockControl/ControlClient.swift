import Foundation

public struct ControlClient: Sendable {
    private let lifecycle: DaemonLifecycle

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.lifecycle = DaemonLifecycle(homeDirectory: homeDirectory)
    }

    public func snapshot() async -> ControlSnapshot {
        await Task.detached(priority: .userInitiated) {
            let socketPath = self.lifecycle.paths.socket.path
            let managed = self.lifecycle.isLoaded()
            let socketExists = FileManager.default.fileExists(atPath: socketPath)
            let http = UnixSocketHTTPClient(socketPath: socketPath)
            do {
                let ping = try http.request(method: "GET", path: "/_ping")
                try Self.requireSuccess(ping)
            } catch {
                let state: DaemonState = managed ? (socketExists ? .unhealthy : .starting) : .stopped
                return ControlSnapshot(
                    daemon: DaemonStatus(
                        state: state,
                        healthy: false,
                        managed: managed,
                        socketPath: socketPath,
                        socketExists: socketExists,
                        socketReachable: false,
                        message: error.localizedDescription
                    ),
                    containers: [],
                    diagnostics: self.lifecycle.diagnostics(managed: managed, reachable: false)
                )
            }

            do {
                let version = try Self.version(using: http)
                let containers: [ContainerSummary]
                let containerMessage: String?
                do {
                    containers = try Self.containers(using: http)
                    containerMessage = nil
                } catch {
                    containers = []
                    containerMessage = "Container data is unavailable: \(error.localizedDescription)"
                }
                return ControlSnapshot(
                    daemon: DaemonStatus(
                        state: .running,
                        healthy: true,
                        managed: managed,
                        socketPath: socketPath,
                        socketExists: true,
                        socketReachable: true,
                        version: version.Components.first(where: { $0.Name == "glassdock" })?.Version,
                        apiVersion: version.ApiVersion,
                        gitCommit: version.GitCommit,
                        buildTime: version.BuildTime,
                        message: containerMessage
                    ),
                    containers: containers,
                    diagnostics: self.lifecycle.diagnostics(managed: managed, reachable: true)
                )
            } catch {
                return ControlSnapshot(
                    daemon: DaemonStatus(
                        state: managed ? .starting : .unhealthy,
                        healthy: false,
                        managed: managed,
                        socketPath: socketPath,
                        socketExists: socketExists,
                        socketReachable: true,
                        message: error.localizedDescription
                    ),
                    containers: [],
                    diagnostics: self.lifecycle.diagnostics(managed: managed, reachable: true)
                )
            }
        }.value
    }

    public func perform(_ action: ControlAction) async throws -> ActionResult {
        try await Task.detached(priority: .userInitiated) {
            try ControlOperationLock.withLock(
                at: self.lifecycle.paths.controlLock
            ) {
                switch action {
                case .startDaemon:
                    let decision = try DaemonSafety.validate(
                        .start,
                        managed: self.lifecycle.isLoaded(),
                        reachable: Self.daemonReachable(socketPath: self.lifecycle.paths.socket.path),
                        runningContainers: []
                    )
                    if case .noChange(let message) = decision {
                        return ActionResult(succeeded: true, message: message)
                    }
                    try self.lifecycle.start()
                    return ActionResult(succeeded: true, message: "Glass Dock is starting.")
                case .stopDaemon:
                    let context = try Self.daemonSafetyContext(lifecycle: self.lifecycle)
                    let decision = try DaemonSafety.validate(
                        .stop,
                        managed: context.managed,
                        reachable: context.reachable,
                        runningContainers: context.runningContainers
                    )
                    if case .noChange(let message) = decision {
                        return ActionResult(succeeded: true, message: message)
                    }
                    try self.lifecycle.stop()
                    return ActionResult(succeeded: true, message: "Glass Dock stopped.")
                case .restartDaemon:
                    let context = try Self.daemonSafetyContext(lifecycle: self.lifecycle)
                    _ = try DaemonSafety.validate(
                        .restart,
                        managed: context.managed,
                        reachable: context.reachable,
                        runningContainers: context.runningContainers
                    )
                    try self.lifecycle.restart()
                    return ActionResult(succeeded: true, message: "Glass Dock is restarting.")
                case .startContainer(let identifier):
                    try Self.containerAction(
                        "start", identifier: identifier,
                        socketPath: self.lifecycle.paths.socket.path)
                    return ActionResult(succeeded: true, message: "Container started.")
                case .stopContainer(let identifier):
                    try Self.containerAction(
                        "stop", identifier: identifier,
                        socketPath: self.lifecycle.paths.socket.path)
                    return ActionResult(succeeded: true, message: "Container stopped.")
                }
            }
        }.value
    }

    public func daemonLogs(maximumBytes: Int = 128_000) async throws -> [LogOutput] {
        try await Task.detached(priority: .utility) {
            try [
                Self.readLog(self.lifecycle.paths.standardOutputLog, maximumBytes: maximumBytes),
                Self.readLog(self.lifecycle.paths.standardErrorLog, maximumBytes: maximumBytes),
            ].compactMap { $0 }
        }.value
    }

    public func supportReport(maximumLogBytes: Int = 64_000) async -> SupportReport {
        async let snapshot = snapshot()
        async let logs = try? daemonLogs(maximumBytes: maximumLogBytes)
        return await SupportReport(snapshot: snapshot, recentLogs: logs ?? [])
    }

    public func containerLogs(identifier: String) async throws -> LogOutput {
        try await Task.detached(priority: .userInitiated) {
            let escaped = try Self.pathSegment(identifier)
            let result = try UnixSocketHTTPClient(
                socketPath: self.lifecycle.paths.socket.path,
                timeout: 15
            ).request(
                method: "GET",
                path: "/containers/\(escaped)/logs?stdout=1&stderr=1"
            )
            try Self.requireSuccess(result)
            let text = Self.decodeDockerLogStream(result.body)
            return LogOutput(source: identifier, text: text, byteCount: result.body.count)
        }.value
    }

    private static func version(using http: UnixSocketHTTPClient) throws -> DockerVersion {
        let result = try http.request(method: "GET", path: "/version")
        try requireSuccess(result)
        return try JSONDecoder().decode(DockerVersion.self, from: result.body)
    }

    private static func containers(using http: UnixSocketHTTPClient) throws -> [ContainerSummary] {
        let result = try http.request(method: "GET", path: "/containers/json?all=1")
        try requireSuccess(result)
        return try JSONDecoder().decode([DockerContainer].self, from: result.body).map {
            ContainerSummary(
                id: $0.Id,
                name: $0.Names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? String($0.Id.prefix(12)),
                image: $0.Image,
                state: $0.State,
                status: $0.Status
            )
        }
    }

    private static func containerAction(_ operation: String, identifier: String, socketPath: String) throws {
        let escaped = try pathSegment(identifier)
        let result = try UnixSocketHTTPClient(socketPath: socketPath, timeout: 20).request(
            method: "POST",
            path: "/containers/\(escaped)/\(operation)"
        )
        try requireSuccess(result, alsoAllowing: [304])
    }

    private static func daemonReachable(socketPath: String) -> Bool {
        guard let result = try? UnixSocketHTTPClient(socketPath: socketPath).request(method: "GET", path: "/_ping") else {
            return false
        }
        return (200..<300).contains(result.status)
    }

    private static func daemonSafetyContext(lifecycle: DaemonLifecycle) throws -> (
        managed: Bool, reachable: Bool, runningContainers: [ContainerSummary]
    ) {
        let reachable = daemonReachable(socketPath: lifecycle.paths.socket.path)
        let runningContainers: [ContainerSummary]
        if reachable {
            runningContainers = try containers(
                using: UnixSocketHTTPClient(socketPath: lifecycle.paths.socket.path)
            ).filter(\.isRunning)
        } else {
            runningContainers = []
        }
        return (lifecycle.isLoaded(), reachable, runningContainers)
    }

    private static func requireSuccess(_ result: HTTPResult, alsoAllowing: Set<Int> = []) throws {
        guard (200..<300).contains(result.status) || alsoAllowing.contains(result.status) else {
            let message =
                (try? JSONDecoder().decode(DockerError.self, from: result.body).message)
                ?? String(data: result.body, encoding: .utf8)
                ?? "Unknown error"
            throw ControlError.requestFailed(status: result.status, message: message)
        }
    }

    private static func pathSegment(_ value: String) throws -> String {
        guard !value.isEmpty,
            let escaped = value.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
            ), !escaped.isEmpty
        else {
            throw ControlError.invalidContainerIdentifier
        }
        return escaped
    }

    private static func readLog(_ url: URL, maximumBytes: Int) throws -> LogOutput? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let boundedBytes = max(0, maximumBytes)
        let truncated = length > UInt64(boundedBytes)
        let start = truncated ? length - UInt64(boundedBytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        return LogOutput(
            source: url.lastPathComponent,
            text: String(decoding: data, as: UTF8.self),
            truncated: truncated,
            byteCount: data.count
        )
    }

    static func decodeDockerLogStream(_ data: Data) -> String {
        guard data.count >= 8, data[0] == 1 || data[0] == 2, data[1...3].allSatisfy({ $0 == 0 }) else {
            return String(decoding: data, as: UTF8.self)
        }
        var cursor = 0
        var output = Data()
        while cursor + 8 <= data.count {
            let length = data[(cursor + 4)..<(cursor + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let payloadStart = cursor + 8
            let payloadEnd = payloadStart + Int(length)
            guard payloadEnd <= data.count else { break }
            output.append(data[payloadStart..<payloadEnd])
            cursor = payloadEnd
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct DockerVersion: Decodable {
    struct Component: Decodable {
        let Name: String
        let Version: String
    }

    let Components: [Component]
    let ApiVersion: String
    let GitCommit: String
    let BuildTime: String
}

private struct DockerContainer: Decodable {
    let Id: String
    let Names: [String]
    let Image: String
    let State: String
    let Status: String
}

private struct DockerError: Decodable {
    let message: String
}
