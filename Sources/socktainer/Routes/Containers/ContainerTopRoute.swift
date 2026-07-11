import ContainerAPIClient
import Foundation
import Vapor

struct ContainerTopQuery: Vapor.Content {
    let ps_args: String?
}

protocol GuestCommandRunning: Sendable {
    func run(containerId: String, command: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String)
}

struct GuestCommandRunner: GuestCommandRunning {
    func run(containerId: String, command: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let containerClient = ContainerClient()
        let container = try await containerClient.get(id: containerId)

        var processConfig = container.configuration.initProcess
        processConfig.executable = command[0]
        processConfig.arguments = Array(command.dropFirst())
        processConfig.terminal = false

        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw Abort(.internalServerError, reason: "Failed to create I/O pipes")
        }
        let process: ClientProcess
        do {
            process = try await containerClient.createProcess(
                containerId: containerId,
                processId: "top-\(UUID().uuidString.lowercased())",
                configuration: processConfig,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw error
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw error
        }
        let (exitCode, stdoutData, stderrData) = try await pipes.collectOutput {
            try await process.wait()
        }
        return (
            exitCode,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

enum PsParseError: Error, Equatable {
    case missingPidField
    case unexpectedPid(String)

    var message: String {
        switch self {
        case .missingPidField: return "Couldn't find PID field in ps output"
        case .unexpectedPid(let pid): return "Unexpected pid '\(pid)'"
        }
    }
}

/// Mirrors moby's `parsePSOutput` (daemon/top_unix.go, v28.5.2): first line is
/// the titles, the last column greedily absorbs overhanging fields so commands
/// with spaces stay whole, a PID column is mandatory, rows are kept only for
/// `containedPids`, and "-" PID thread rows (`ps m`) follow their process.
enum PsOutputParser {
    static func parse(_ output: String, containedPids: Set<Int>) throws -> RESTContainerTop {
        let lines = output.split(separator: "\n").map(String.init)
        let titles = asciiFields(of: lines.first ?? "")
        guard let pidIndex = titles.firstIndex(of: "PID") else {
            throw PsParseError.missingPidField
        }

        var processes: [[String]] = []
        var previousRowContained = false
        for line in lines.dropFirst() {
            let columns = asciiFields(of: line)
            guard columns.count >= titles.count else { continue }
            if columns[pidIndex] == "-" {
                if previousRowContained { processes.append(processRow(columns, titleCount: titles.count)) }
                continue
            }
            guard let pid = Int(columns[pidIndex]) else {
                throw PsParseError.unexpectedPid(columns[pidIndex])
            }
            previousRowContained = containedPids.contains(pid)
            if previousRowContained {
                processes.append(processRow(columns, titleCount: titles.count))
            }
        }
        return RESTContainerTop(Titles: titles, Processes: processes)
    }

    /// ASCII whitespace only, like moby's `fieldsASCII` — unicode spaces inside
    /// command names must not split columns (moby PR #24358).
    private static func asciiFields(of line: String) -> [String] {
        line.split(whereSeparator: { "\t\n\u{0C}\r ".contains($0) }).map(String.init)
    }

    private static func processRow(_ columns: [String], titleCount: Int) -> [String] {
        var row = Array(columns.prefix(titleCount - 1))
        row.append(columns.dropFirst(titleCount - 1).joined(separator: " "))
        return row
    }
}

struct ContainerTopRoute: RouteCollection {
    let client: ClientContainerProtocol
    let runner: GuestCommandRunning

    init(client: ClientContainerProtocol, runner: GuestCommandRunning = GuestCommandRunner()) {
        self.client = client
        self.runner = runner
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/top", use: ContainerTopRoute.handler(client: client, runner: runner))
    }

    static func effectivePsArgs(_ raw: String?) -> String {
        raw.flatMap { $0.isEmpty ? nil : $0 } ?? "-ef"
    }

    /// moby's `validatePSArgs`: renaming a column header to `PID*` (e.g.
    /// `-o user=PID`) is rejected so a forged header can't confuse the parser.
    static func forbiddenPidRename(in psArgs: String) -> String? {
        let renamedPidColumn = /\s+([^\s]*)=\s*(PID[^\s]*)/
        for match in psArgs.matches(of: renamedPidColumn) where match.1 != "pid" {
            return "\(match.1)=\(match.2)"
        }
        return nil
    }

    static func psCommand(psArgs: String) -> [String] {
        ["ps"] + psArgs.split(separator: " ").map(String.init)
    }

    static func psPidsArg(_ pids: [Int]) -> String {
        "-q" + pids.map(String.init).joined(separator: ",")
    }

    static func psFailureMessage(stderr: String, exitCode: Int32) -> String {
        let firstStderrLine = stderr.split(separator: "\n").first.map(String.init)
        return "ps: \(firstStderrLine ?? "exit status \(exitCode)")"
    }

    static let pidSnapshotCommand = ["ps", "-eo", "pid="]

    static func parsePids(_ output: String) -> [Int] {
        output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    }

    /// moby runs `ps <args> -q<pids>` and retries without `-q` when the args
    /// conflict with it (e.g. BSD `f`); the parser's pid filter covers both paths.
    static func runPs(runner: GuestCommandRunning, containerId: String, command: [String], pids: [Int]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let filtered = try await runner.run(containerId: containerId, command: command + [psPidsArg(pids)])
        if filtered.exitCode == 0 { return filtered }
        return try await runner.run(containerId: containerId, command: command)
    }

    static func handler(client: ClientContainerProtocol, runner: GuestCommandRunning) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let reference = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Container ID is required")
            }
            let query = try req.query.decode(ContainerTopQuery.self)
            let psArgs = effectivePsArgs(query.ps_args)
            if let rename = forbiddenPidRename(in: psArgs) {
                return Response(status: .badRequest, body: .init(string: "specifying \"\(rename)\" is not allowed"))
            }
            let command = psCommand(psArgs: psArgs)

            do {
                guard let container = try await client.getContainer(id: reference) else {
                    return Response(status: .notFound, body: .init(string: "container \(reference) not found"))
                }
                try client.enforceContainerRunning(container: container)

                let pidSnapshot = try await runner.run(containerId: container.id, command: pidSnapshotCommand)
                guard pidSnapshot.exitCode == 0 else {
                    return Response(status: .internalServerError, body: .init(string: psFailureMessage(stderr: pidSnapshot.stderr, exitCode: pidSnapshot.exitCode)))
                }
                let pids = parsePids(pidSnapshot.stdout)
                let result = try await runPs(runner: runner, containerId: container.id, command: command, pids: pids)
                guard result.exitCode == 0 else {
                    return Response(status: .internalServerError, body: .init(string: psFailureMessage(stderr: result.stderr, exitCode: result.exitCode)))
                }
                let top = try PsOutputParser.parse(result.stdout, containedPids: Set(pids))

                if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                    let event = DockerEvent.simpleEvent(
                        id: DockerContainerID.hexId(for: container),
                        type: "container",
                        status: "top",
                        image: container.configuration.image.reference,
                        name: container.id,
                        labels: LabelNormalization.restore(container.configuration.labels)
                    )
                    await broadcaster.broadcast(event)
                }
                return try await top.encodeResponse(status: .ok, for: req)
            } catch let parseError as PsParseError {
                return Response(status: .internalServerError, body: .init(string: parseError.message))
            } catch ClientContainerError.notRunning {
                return Response(status: .conflict, body: .init(string: "container \(reference) is not running"))
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                return Response(status: .badRequest, body: .init(string: "ambiguous container reference \(reference): matches \(matchList)"))
            } catch let abort as Abort {
                throw abort
            } catch {
                req.logger.error("Failed to run top in container \(reference): \(error)")
                return Response(status: .internalServerError, body: .init(string: "Failed to run ps in container: \(error)"))
            }
        }
    }
}
