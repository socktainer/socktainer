import Darwin
import Foundation

protocol RuntimeMachineProcess: Sendable {
    var processIdentifier: Int32 { get }
    func waitUntilReady(generation: UUID) async throws
    func waitForExit() async -> Int32
    func stop() async throws
}

protocol RuntimeMachineProcessLaunching: Sendable {
    func launch(
        configuration: RuntimeMachineConfiguration,
        generation: UUID,
        runtimeDirectory: URL
    ) throws -> any RuntimeMachineProcess
}

struct FoundationRuntimeMachineProcessLauncher: RuntimeMachineProcessLaunching {
    func launch(
        configuration: RuntimeMachineConfiguration,
        generation: UUID,
        runtimeDirectory: URL
    ) throws -> any RuntimeMachineProcess {
        guard FileManager.default.isExecutableFile(atPath: configuration.helperExecutable.path) else {
            throw RuntimeMachineError.helperLaunch(
                "VMM helper is not executable: \(configuration.helperExecutable.path)"
            )
        }

        let controlSocket =
            runtimeDirectory
            .appendingPathComponent("vsock/1025.sock", isDirectory: false)
        let process = Process()
        process.executableURL = configuration.helperExecutable
        process.arguments = Self.arguments(
            configuration: configuration,
            runtimeDirectory: runtimeDirectory
        )
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw RuntimeMachineError.helperLaunch(String(describing: error))
        }
        return FoundationRuntimeMachineProcess(
            process: process,
            readinessSockets: [controlSocket]
        )
    }

    static func arguments(
        configuration: RuntimeMachineConfiguration,
        runtimeDirectory: URL
    ) -> [String] {
        [
            "--parent-pid", String(Darwin.getpid()),
            "--kernel", configuration.kernel.path,
            "--root-disk", configuration.rootDisk.path,
            "--data-disk", configuration.dataDisk.path,
            "--bind-source", configuration.bindSource.path,
            "--excluded-bind-source", configuration.stateDirectory.path,
            "--control-socket",
            runtimeDirectory.appendingPathComponent("vsock/1025.sock").path,
            "--console-log",
            runtimeDirectory.appendingPathComponent("console.log").path,
            "--cpus", String(configuration.cpuCount),
            "--memory-mib", String(configuration.memoryBytes / (1024 * 1024)),
        ]
    }
}

private final class FoundationRuntimeMachineProcess: RuntimeMachineProcess, @unchecked Sendable {
    let processIdentifier: Int32

    private let process: Process
    private let readinessSockets: [URL]
    private let exitTask: Task<Int32, Never>

    init(process: Process, readinessSockets: [URL]) {
        self.process = process
        self.readinessSockets = readinessSockets
        self.processIdentifier = process.processIdentifier
        let processIdentifier = process.processIdentifier
        self.exitTask = Task.detached {
            process.waitUntilExit()
            _ = Darwin.kill(-processIdentifier, SIGTERM)
            return process.terminationStatus
        }
    }

    func waitUntilReady(generation: UUID) async throws {
        let sockets = readinessSockets
        let process = self.process
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                throw RuntimeMachineError.helperExited(
                    generation: generation,
                    status: process.terminationStatus,
                    consoleTail: nil
                )
            }
            if sockets.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RuntimeMachineError.invalidReadiness(
            "VMM helper did not create its generation-scoped vsock sockets"
        )
    }

    func waitForExit() async -> Int32 {
        await exitTask.value
    }

    func stop() async throws {
        if process.isRunning {
            process.terminate()
            let deadline = ContinuousClock.now + .seconds(2)
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        _ = await exitTask.value
    }

}
