import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("PsOutputParser")
struct PsOutputParserTests {

    @Test("procps -ef output: titles from header, CMD absorbs trailing spaces")
    func procpsOutput() throws {
        let output = """
            UID          PID    PPID  C STIME TTY          TIME CMD
            root           1       0  0 10:02 ?        00:00:00 nginx: master process nginx -g daemon off;
            nginx         29       1  0 10:02 ?        00:00:00 nginx: worker process
            root          42       1  0 10:05 ?        00:00:00 ps -ef
            """
        let top = try PsOutputParser.parse(output, containedPids: [1, 29])
        #expect(top.Titles == ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
        #expect(top.Processes.count == 2)
        #expect(top.Processes[0] == ["root", "1", "0", "0", "10:02", "?", "00:00:00", "nginx: master process nginx -g daemon off;"])
        #expect(top.Processes[1][7] == "nginx: worker process")
    }

    @Test("busybox output parses with its four-column header")
    func busyboxOutput() throws {
        let output = """
            PID   USER     TIME  COMMAND
                1 root      0:00 /docker-entrypoint.sh redis-server
               12 root      0:00 ps -ef
            """
        let top = try PsOutputParser.parse(output, containedPids: [1])
        #expect(top.Titles == ["PID", "USER", "TIME", "COMMAND"])
        #expect(top.Processes == [["1", "root", "0:00", "/docker-entrypoint.sh redis-server"]])
    }

    @Test("rows outside the pid snapshot are dropped — the exec'd ps excludes itself")
    func filtersRowsByPidSnapshot() throws {
        let output = """
            PID   USER     TIME  COMMAND
                1 root      0:00 sh -c while true; do ps -ef; sleep 1; done
                7 root      0:00 ps -ef
               12 root      0:00 ps -ef
            """
        let top = try PsOutputParser.parse(output, containedPids: [1, 7])
        #expect(top.Processes.count == 2)
        #expect(top.Processes[1] == ["7", "root", "0:00", "ps -ef"])
    }

    @Test("lines with fewer fields than titles are skipped")
    func skipsMalformedLines() throws {
        let output = """
            PID   USER     TIME  COMMAND
                1 root      0:00 nginx
            broken line
            """
        let top = try PsOutputParser.parse(output, containedPids: [1])
        #expect(top.Processes == [["1", "root", "0:00", "nginx"]])
    }

    @Test("'-' PID thread rows follow their process's fate, moby issue #30580")
    func threadRowsFollowTheirProcess() throws {
        let output = """
            UID          PID    PPID  C STIME TTY          TIME CMD
            root           -       0  0 10:02 ?        00:00:00 orphan thread
            root           1       0  0 10:02 ?        00:00:00 java -jar app.jar
            root           -       1  0 10:02 ?        00:00:00 java -jar app.jar
            root          99       1  0 10:02 ?        00:00:00 ps m
            root           -      99  0 10:02 ?        00:00:00 ps m
            """
        let top = try PsOutputParser.parse(output, containedPids: [1])
        #expect(top.Processes.count == 2)
        #expect(top.Processes[0][1] == "1")
        #expect(top.Processes[1][1] == "-")
    }

    @Test("output without a PID column throws like moby")
    func missingPidColumn() {
        #expect(throws: PsParseError.missingPidField) {
            try PsOutputParser.parse("USER\nroot", containedPids: [1])
        }
        #expect(throws: PsParseError.missingPidField) {
            try PsOutputParser.parse("", containedPids: [1])
        }
    }

    @Test("a non-numeric PID throws like moby")
    func unexpectedPid() {
        #expect(throws: PsParseError.unexpectedPid("abc")) {
            try PsOutputParser.parse("PID USER\nabc root", containedPids: [1])
        }
    }

    @Test("unicode spaces inside a command name do not split columns")
    func unicodeSpaceInCommandName() throws {
        let output = "PID COMMAND\n1 spring\u{00A0}boot-app"
        let top = try PsOutputParser.parse(output, containedPids: [1])
        #expect(top.Processes == [["1", "spring\u{00A0}boot-app"]])
    }
}

@Suite("ContainerTopRoute")
struct ContainerTopRouteTests {

    @Test("ps_args defaults to -ef and splits on single spaces")
    func psCommandConstruction() {
        #expect(ContainerTopRoute.effectivePsArgs(nil) == "-ef")
        #expect(ContainerTopRoute.effectivePsArgs("") == "-ef")
        #expect(ContainerTopRoute.effectivePsArgs("aux") == "aux")
        #expect(ContainerTopRoute.psCommand(psArgs: "aux") == ["ps", "aux"])
        #expect(ContainerTopRoute.psCommand(psArgs: "-o  pid,user") == ["ps", "-o", "pid,user"])
    }

    @Test("pid snapshot output parses into pids, pids render as moby's -q argument")
    func pidPlumbing() {
        #expect(ContainerTopRoute.parsePids("    1\n   12\n") == [1, 12])
        #expect(ContainerTopRoute.parsePids("PID\n1\n") == [1])
        #expect(ContainerTopRoute.psPidsArg([1, 12, 30]) == "-q1,12,30")
    }

    @Test("renaming a column to PID is rejected like moby's validatePSArgs")
    func forbiddenPidRename() {
        #expect(ContainerTopRoute.forbiddenPidRename(in: "-o user=PID") == "user=PID")
        #expect(ContainerTopRoute.forbiddenPidRename(in: "-o pid=PID") == nil)
        #expect(ContainerTopRoute.forbiddenPidRename(in: "-ef") == nil)
        #expect(ContainerTopRoute.forbiddenPidRename(in: "aux") == nil)
    }

    @Test("running container returns Titles and Processes from guest ps")
    func topReturnsProcesses() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = RecordingGuestCommandRunner(results: [
            .ok("1\n11"),
            .ok(
                """
                PID   USER     TIME  COMMAND
                    1 root      0:00 nginx -g daemon off;
                   12 root      0:00 ps -ef -q1,11
                """),
        ])
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async throws in
                #expect(res.status == .ok)
                let top = try res.content.decode(RESTContainerTop.self)
                #expect(top.Titles == ["PID", "USER", "TIME", "COMMAND"])
                #expect(top.Processes == [["1", "root", "0:00", "nginx -g daemon off;"]])
            }
        }
        #expect(await runner.commands == [["ps", "-eo", "pid="], ["ps", "-ef", "-q1,11"]])
    }

    @Test("ps_args is forwarded to the guest ps invocation with the pid filter")
    func psArgsForwarded() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = RecordingGuestCommandRunner(results: [
            .ok("1"),
            .ok("PID USER\n1 root"),
        ])
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top?ps_args=-o%20pid,user") { res async in
                #expect(res.status == .ok)
            }
        }
        #expect(await runner.commands == [["ps", "-eo", "pid="], ["ps", "-o", "pid,user", "-q1"]])
    }

    @Test("when ps rejects -q the route retries without it, like moby")
    func retriesWithoutPidFilter() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = RecordingGuestCommandRunner(results: [
            .ok("1"),
            .failed("ps: q requires an argument"),
            .ok("PID USER\n1 root\n31 root"),
        ])
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top?ps_args=f") { res async throws in
                #expect(res.status == .ok)
                let top = try res.content.decode(RESTContainerTop.self)
                #expect(top.Processes == [["1", "root"]])
            }
        }
        #expect(await runner.commands == [["ps", "-eo", "pid="], ["ps", "f", "-q1"], ["ps", "f"]])
    }

    @Test("unknown container returns 404")
    func unknownContainer() async throws {
        try await withTopApp(snapshot: nil, runner: RecordingGuestCommandRunner(results: [])) { app in
            try await app.testing().test(.GET, "/v1.51/containers/ghost/top") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("stopped container returns 409")
    func stoppedContainer() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        try await withTopApp(snapshot: snapshot, runner: RecordingGuestCommandRunner(results: [])) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("PID-renaming ps_args is rejected with 400 before touching the container")
    func forbiddenPsArgsRejected() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = RecordingGuestCommandRunner(results: [])
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top?ps_args=-o%20user%3DPID") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains(#"specifying "user=PID" is not allowed"#))
            }
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test("a scratch image without a ps binary gets a self-explanatory 500")
    func missingPsBinary() async throws {
        struct VmexecError: Error, CustomStringConvertible {
            var description: String {
                #"internalError: "vmexec error: internalError: "failed to find target executable ps""#
            }
        }
        let snapshot = try makeContainerSnapshot(nativeId: "scratch-app", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = ThrowingGuestCommandRunner(error: VmexecError())
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/scratch-app/top") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("requires a ps binary inside the container image"))
            }
        }
    }

    @Test("pid snapshot failure surfaces as 500 with moby's message shape")
    func pidSnapshotFailure() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = RecordingGuestCommandRunner(results: [.failed("ps: not found")])
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string == "ps: ps: not found")
            }
        }
    }

    @Test("ps failing with and without -q surfaces the retry's stderr as 500")
    func psFailure() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = RecordingGuestCommandRunner(results: [
            .ok("1"),
            .failed("ps: unrecognized option: z\nusage: ps [-o COL]"),
            .failed("ps: unrecognized option: z\nusage: ps [-o COL]"),
        ])
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top?ps_args=-z") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string == "ps: ps: unrecognized option: z")
            }
        }
    }

    @Test("unparseable ps output surfaces as 500 with moby's message")
    func unparseableOutput() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let runner = RecordingGuestCommandRunner(results: [.ok("1"), .ok("")])
        try await withTopApp(snapshot: snapshot, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("Couldn't find PID field in ps output"))
            }
        }
    }

    @Test("successful top broadcasts a container 'top' event like moby")
    func topEmitsEvent() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "top" && event.Type == "container" {
                return event
            }
            return nil
        }

        let runner = RecordingGuestCommandRunner(results: [
            .ok("1"),
            .ok(
                """
                PID   USER     TIME  COMMAND
                    1 root      0:00 nginx
                """),
        ])
        try await withTopApp(snapshot: snapshot, runner: runner, broadcaster: broadcaster) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async in
                #expect(res.status == .ok)
            }
        }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            captureTask.cancel()
        }
        let event = await captureTask.value
        timeout.cancel()

        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["name"] == "web")
    }
}

// MARK: - Helpers

private func withTopApp(
    snapshot: ContainerSnapshot?,
    runner: GuestCommandRunning,
    broadcaster: EventBroadcaster? = nil,
    test: @escaping (Application) async throws -> Void
) async throws {
    let client: ClientContainerProtocol =
        snapshot.map { StatusEnforcingSnapshotClientMock(snapshot: $0) } ?? NoContainerClientMock()
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        if let broadcaster {
            app.storage[EventBroadcasterKey.self] = broadcaster
        }
        try app.register(collection: ContainerTopRoute(client: client, runner: runner))
        try await test(app)
    }
}

private struct GuestRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    static func ok(_ stdout: String) -> GuestRunResult { GuestRunResult(exitCode: 0, stdout: stdout, stderr: "") }
    static func failed(_ stderr: String) -> GuestRunResult { GuestRunResult(exitCode: 1, stdout: "", stderr: stderr) }
}

private struct ThrowingGuestCommandRunner: GuestCommandRunning {
    let error: Error

    func run(containerId: String, command: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        throw error
    }
}

private actor RecordingGuestCommandRunner: GuestCommandRunning {
    private(set) var commands: [[String]] = []
    private var pendingResults: [GuestRunResult]

    init(results: [GuestRunResult]) {
        self.pendingResults = results
    }

    func run(containerId: String, command: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        commands.append(command)
        guard !pendingResults.isEmpty else {
            return (1, "", "RecordingGuestCommandRunner: no canned result for \(command)")
        }
        let result = pendingResults.removeFirst()
        return (result.exitCode, result.stdout, result.stderr)
    }
}

private struct StatusEnforcingSnapshotClientMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {
        guard container.status == .running else {
            throw ClientContainerError.notRunning(id: container.id)
        }
    }
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}

private struct NoContainerClientMock: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
