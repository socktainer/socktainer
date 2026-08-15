import Foundation
import Testing

@testable import GlassDockControl

@Suite("Glass Dock control contract")
struct ControlTests {
    @Test("parses content-length HTTP responses")
    func parsesContentLengthResponse() throws {
        let result = try UnixSocketHTTPClient.parse(
            Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nOK".utf8)
        )

        #expect(result.status == 200)
        #expect(result.headers["content-type"] == "text/plain")
        #expect(String(decoding: result.body, as: UTF8.self) == "OK")
    }

    @Test("parses chunked HTTP responses")
    func parsesChunkedResponse() throws {
        let result = try UnixSocketHTTPClient.parse(
            Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nGlass\r\n5\r\n Dock\r\n0\r\n\r\n".utf8)
        )

        #expect(String(decoding: result.body, as: UTF8.self) == "Glass Dock")
    }

    @Test("rejects a truncated HTTP body")
    func rejectsTruncatedBody() {
        #expect(throws: ControlError.self) {
            try UnixSocketHTTPClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nOK".utf8))
        }
    }

    @Test("decodes Docker multiplexed log frames")
    func decodesDockerLogFrames() {
        var data = Data([1, 0, 0, 0, 0, 0, 0, 4])
        data.append(Data("out\n".utf8))
        data.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 4])
        data.append(Data("err\n".utf8))

        #expect(ControlClient.decodeDockerLogStream(data) == "out\nerr\n")
    }

    @Test("launch agent uses a fixed executable and managed logs")
    func launchAgentPropertyList() throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let paths = LaunchAgentPaths(homeDirectory: home)
        let data = try DaemonLifecycle.launchAgentPropertyList(
            daemonExecutable: URL(fileURLWithPath: "/opt/glassdock/bin/glassdock"),
            paths: paths
        )
        let value = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(value["Label"] as? String == LaunchAgentPaths.label)
        #expect(value["ProgramArguments"] as? [String] == ["/opt/glassdock/bin/glassdock"])
        #expect(value["StandardOutPath"] as? String == "/Users/test/Library/Logs/GlassDock/daemon.log")
        #expect(value["StandardErrorPath"] as? String == "/Users/test/Library/Logs/GlassDock/daemon-error.log")
    }

    @Test("control snapshot keeps its versioned JSON contract")
    func snapshotRoundTrip() throws {
        let snapshot = ControlSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            daemon: DaemonStatus(
                state: .running,
                healthy: true,
                managed: true,
                socketPath: "/tmp/container.sock",
                socketExists: true,
                socketReachable: true,
                version: "1.2.3"
            ),
            containers: [
                ContainerSummary(id: "abc", name: "web", image: "nginx", state: "running", status: "running")
            ],
            diagnostics: ControlDiagnostics(
                ownership: .managedLaunchAgent,
                installation: InstallationInfo(kind: .package, executablePath: "/opt/glassdock/bin/glassdock"),
                paths: ControlPaths(
                    socket: "/tmp/container.sock",
                    logDirectory: "/tmp/logs",
                    standardOutputLog: "/tmp/logs/out",
                    standardErrorLog: "/tmp/logs/err",
                    launchAgent: "/tmp/agent.plist",
                    controlLock: "/tmp/control.lock",
                    defaultEngineStateDirectory: "/tmp/engine"
                ),
                diskSpace: DiskSpaceSignal(
                    volumePath: "/tmp",
                    availableBytes: 50_000_000_000,
                    totalBytes: 100_000_000_000,
                    level: .normal
                )
            )
        )

        let decoded = try JSONDecoder().decode(ControlSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.daemon.socketExists)
        #expect(decoded.daemon.socketReachable)
        #expect(decoded.daemon.virtualMachineHealth == nil)
    }

    @Test("support report includes bounded logs and explicit unavailable signals")
    func supportReportText() {
        let snapshot = ControlSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            daemon: DaemonStatus(
                state: .running,
                healthy: true,
                managed: false,
                socketPath: "/tmp/container.sock",
                socketExists: true,
                socketReachable: true,
                version: "1.2.3",
                apiVersion: "1.51",
                gitCommit: "abc123",
                buildTime: "2026-08-14T00:00:00Z"
            ),
            containers: [],
            diagnostics: ControlDiagnostics(
                ownership: .unmanaged,
                installation: InstallationInfo(kind: .notFound),
                paths: ControlPaths(
                    socket: "/tmp/container.sock",
                    logDirectory: "/tmp/logs",
                    standardOutputLog: "/tmp/logs/out",
                    standardErrorLog: "/tmp/logs/err",
                    launchAgent: "/tmp/agent.plist",
                    controlLock: "/tmp/control.lock",
                    defaultEngineStateDirectory: "/tmp/engine"
                )
            )
        )
        let report = SupportReport(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            snapshot: snapshot,
            recentLogs: [LogOutput(source: "daemon.log", text: "tail", truncated: true, byteCount: 4)]
        )

        #expect(report.schemaVersion == 2)
        #expect(report.text.contains("Control ownership: unmanaged"))
        #expect(report.text.contains("VM health: not reported"))
        #expect(report.text.contains("daemon.log (last 4 bytes; truncated)"))
    }

    @Test("disk-space level reports low and critical capacity")
    func diskSpaceLevel() {
        #expect(DiskSpaceSignal.level(availableBytes: 50_000_000_000, totalBytes: 100_000_000_000) == .normal)
        #expect(DiskSpaceSignal.level(availableBytes: 5_000_000_000, totalBytes: 100_000_000_000) == .low)
        #expect(DiskSpaceSignal.level(availableBytes: 1_000_000_000, totalBytes: 100_000_000_000) == .critical)
    }

    @Test("daemon stop rejects an unmanaged process")
    func rejectsUnmanagedStop() {
        #expect(throws: ControlError.self) {
            try DaemonSafety.validate(
                .stop,
                managed: false,
                reachable: true,
                runningContainers: []
            )
        }
    }

    @Test("daemon lifecycle rejects running containers")
    func rejectsRunningContainers() {
        let running = ContainerSummary(
            id: "abc",
            name: "database",
            image: "postgres",
            state: "running",
            status: "running"
        )

        #expect(throws: ControlError.self) {
            try DaemonSafety.validate(
                .restart,
                managed: true,
                reachable: true,
                runningContainers: [running]
            )
        }
    }

    @Test("daemon start is idempotent")
    func startIsIdempotent() throws {
        let decision = try DaemonSafety.validate(
            .start,
            managed: true,
            reachable: true,
            runningContainers: []
        )

        #expect(decision == .noChange("Glass Dock is already running."))
    }

    @Test("daemon discovery uses the sibling executable")
    func resolvesSiblingDaemon() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let daemon = directory.appendingPathComponent("glassdock")
        #expect(FileManager.default.createFile(atPath: daemon.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemon.path)
        let lifecycle = DaemonLifecycle(
            homeDirectory: directory,
            currentExecutable: directory.appendingPathComponent("glassdockctl")
        )

        #expect(try lifecycle.resolveDaemonExecutable() == daemon.standardizedFileURL)
    }

    @Test("control operation lock is owner-only")
    func controlLockPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("control.lock")

        let result = try ControlOperationLock.withLock(at: lock) { 42 }
        let attributes = try FileManager.default.attributesOfItem(atPath: lock.path)

        #expect(result == 42)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
