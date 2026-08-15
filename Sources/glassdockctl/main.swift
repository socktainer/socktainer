import ArgumentParser
import Foundation
import GlassDockControl

@main
struct GlassDockControlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glassdockctl",
        abstract: "Control the local GlassDock daemon and containers.",
        subcommands: [Status.self, Support.self, Daemon.self, Containers.self, Logs.self]
    )
}

private struct Support: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "support-report",
        abstract: "Create a bounded local support report."
    )

    @Option(help: "Maximum bytes to read from each managed daemon log.")
    var bytes = 64_000

    @Flag(help: "Write the stable JSON control contract.")
    var json = false

    func run() async throws {
        let report = await ControlClient().supportReport(maximumLogBytes: max(0, bytes))
        if json {
            try writeJSON(report)
        } else {
            print(report.text)
        }
    }
}

private struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show daemon health, version, and container status.")

    @Flag(help: "Write the stable JSON control contract.")
    var json = false

    func run() async throws {
        let snapshot = await ControlClient().snapshot()
        if json {
            try writeJSON(snapshot)
            return
        }
        print("GlassDock: \(snapshot.daemon.state.rawValue)")
        print("Health: \(snapshot.daemon.healthy ? "healthy" : "unavailable")")
        if let version = snapshot.daemon.version { print("Version: \(version)") }
        if let apiVersion = snapshot.daemon.apiVersion { print("Docker API: \(apiVersion)") }
        print("Containers: \(snapshot.containers.filter(\.isRunning).count) running, \(snapshot.containers.count) total")
        if let message = snapshot.daemon.message { print("Detail: \(message)") }
    }
}

private struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start, stop, or restart the managed daemon.",
        subcommands: [Start.self, Stop.self, Restart.self]
    )

    struct Start: AsyncParsableCommand {
        @Flag var json = false
        func run() async throws { try await runAction(.startDaemon, json: json) }
    }

    struct Stop: AsyncParsableCommand {
        @Flag var json = false
        func run() async throws { try await runAction(.stopDaemon, json: json) }
    }

    struct Restart: AsyncParsableCommand {
        @Flag var json = false
        func run() async throws { try await runAction(.restartDaemon, json: json) }
    }
}

private struct Containers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and control containers.",
        subcommands: [List.self, Start.self, Stop.self]
    )

    struct List: AsyncParsableCommand {
        @Flag(help: "Write the stable JSON control contract.")
        var json = false

        func run() async throws {
            let snapshot = await ControlClient().snapshot()
            guard snapshot.daemon.healthy else {
                throw ValidationError(snapshot.daemon.message ?? "GlassDock is not available.")
            }
            if json {
                try writeJSON(snapshot.containers)
            } else if snapshot.containers.isEmpty {
                print("No containers.")
            } else {
                for container in snapshot.containers {
                    print("\(container.name)\t\(container.state)\t\(container.image)\t\(container.id.prefix(12))")
                }
            }
        }
    }

    struct Start: AsyncParsableCommand {
        @Argument(help: "Container ID or name.") var identifier: String
        @Flag var json = false
        func run() async throws { try await runAction(.startContainer(identifier), json: json) }
    }

    struct Stop: AsyncParsableCommand {
        @Argument(help: "Container ID or name.") var identifier: String
        @Flag var json = false
        func run() async throws { try await runAction(.stopContainer(identifier), json: json) }
    }

}

private struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read bounded daemon or container logs.",
        subcommands: [DaemonLogs.self, ContainerLogs.self]
    )

    struct DaemonLogs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "daemon")
        @Option(help: "Maximum bytes to read from each log.") var bytes = 128_000
        @Flag var json = false

        func run() async throws {
            let output = try await ControlClient().daemonLogs(maximumBytes: max(0, bytes))
            if json {
                try writeJSON(output)
            } else {
                for log in output { print("== \(log.source) ==\n\(log.text)") }
            }
        }
    }

    struct ContainerLogs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "container")
        @Argument(help: "Container ID or name.") var identifier: String
        @Flag var json = false

        func run() async throws {
            let output = try await ControlClient().containerLogs(identifier: identifier)
            if json { try writeJSON(output) } else { print(output.text, terminator: "") }
        }
    }
}

private func runAction(_ action: ControlAction, json: Bool) async throws {
    do {
        let result = try await ControlClient().perform(action)
        if json { try writeJSON(result) } else { print(result.message) }
    } catch {
        throw ValidationError(error.localizedDescription)
    }
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}
