import Foundation
import Logging

struct EngineMachine: Sendable, Equatable {
    let id: String
    let containerID: String
    let ipAddress: String
    let running: Bool
}

protocol EngineMachineControlling: Sendable {
    func inspect(id: String) async throws -> EngineMachine?
    func provision(id: String) async throws
    func boot(id: String) async throws -> EngineMachine
    func dial(containerID: String, port: UInt32) async throws -> FileHandle
    func setMemoryTarget(_ bytes: UInt64) async throws
    func stop(id: String) async throws
}

enum PersistentEngineError: Error, Equatable {
    case invalidMachineSnapshot(String)
}

/// Owns the complete host-side lifecycle of the one persistent engine VM.
/// Callers learn one operation: obtain a ready multiplexed guest connection.
actor PersistentEngine {
    static let machineID = "socktainer-engine"
    static let guestPort: UInt32 = 1025
    static let publishedPortProxyPort: UInt32 = 1026
    static let configuredMemoryBytes: UInt64 = 1_024 * 1024 * 1024
    static let idleMemoryBytes: UInt64 = 384 * 1024 * 1024

    private let controller: any EngineMachineControlling
    private let logger: Logger
    private var connection: GuestConnection?
    private var machine: EngineMachine?
    private struct Readiness {
        let token: UUID
        let task: Task<(GuestConnection, EngineMachine), Error>
    }
    private var readiness: Readiness?
    private var activeWork = 0
    private var reclaimTask: Task<Void, Never>?

    init(
        controller: any EngineMachineControlling,
        logger: Logger = Logger(label: "socktainer.engine")
    ) {
        self.controller = controller
        self.logger = logger
    }

    func readyConnection() async throws -> GuestConnection {
        if let connection { return connection }

        let current: Readiness
        if let readiness {
            current = readiness
        } else {
            current = Readiness(
                token: UUID(),
                task: Task { try await self.establishConnection() }
            )
            readiness = current
        }
        do {
            let (connection, snapshot) = try await current.task.value
            if readiness?.token == current.token { readiness = nil }
            self.machine = snapshot
            self.connection = connection
            return connection
        } catch {
            if readiness?.token == current.token { readiness = nil }
            throw error
        }
    }

    private func establishConnection() async throws -> (GuestConnection, EngineMachine) {
        var snapshot = try await controller.inspect(id: Self.machineID)
        if snapshot == nil {
            try await controller.provision(id: Self.machineID)
            snapshot = try await controller.inspect(id: Self.machineID)
        }
        guard var snapshot else {
            throw PersistentEngineError.invalidMachineSnapshot("machine does not exist after provisioning")
        }
        if !snapshot.running {
            snapshot = try await controller.boot(id: Self.machineID)
        }
        let containerID = snapshot.containerID
        let controller = self.controller
        var lastError: Error?
        var ready: GuestConnection?
        for _ in 0..<10_000 {
            do {
                ready = try await GuestConnection.connect {
                    try await controller.dial(containerID: containerID, port: Self.guestPort)
                }
                break
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        guard let connection = ready else {
            try? await controller.stop(id: Self.machineID)
            throw lastError ?? GuestConnectionError.closed
        }
        let response = try await connection.request(method: "ping", payload: .object([:]))
        guard response.kind == .response,
            response.payload == .object(["ok": .bool(true)])
        else {
            await connection.close()
            try? await controller.stop(id: Self.machineID)
            throw PersistentEngineError.invalidMachineSnapshot("guest ping returned an invalid response")
        }
        do {
            try await controller.setMemoryTarget(Self.idleMemoryBytes)
        } catch {
            await connection.close()
            try? await controller.stop(id: Self.machineID)
            throw error
        }
        self.machine = snapshot
        logger.info("persistent engine is ready", metadata: ["ip": "\(snapshot.ipAddress)"])
        return (connection, snapshot)
    }

    func invalidateConnection() async {
        await connection?.close()
        connection = nil
        readiness?.task.cancel()
        readiness = nil
    }

    func invalidateConnection(_ expected: GuestConnection) async {
        guard connection === expected else { return }
        await expected.close()
        connection = nil
    }

    func shutdown() async {
        reclaimTask?.cancel()
        if let connection {
            _ = try? await connection.request(method: "engine.sync", payload: .object([:]))
            await connection.close()
        }
        connection = nil
        machine = nil
        do {
            try await controller.stop(id: Self.machineID)
        } catch {
            logger.error("failed to stop persistent engine", metadata: ["error": "\(error)"])
        }
    }

    func prepareForWork() async throws {
        reclaimTask?.cancel()
        reclaimTask = nil
        if activeWork == 0 {
            try await controller.setMemoryTarget(Self.configuredMemoryBytes)
        }
        activeWork += 1
    }

    func finishedWork() {
        activeWork = max(0, activeWork - 1)
        guard activeWork == 0 else { return }
        reclaimTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? await self?.reclaimIdleMemory()
        }
    }

    private func reclaimIdleMemory() async throws {
        guard activeWork == 0 else { return }
        try await controller.setMemoryTarget(Self.idleMemoryBytes)
    }

    func address() -> String? {
        machine?.ipAddress
    }

    func dialPublishedPortProxy() async throws -> FileHandle {
        _ = try await readyConnection()
        guard let machine else {
            throw PersistentEngineError.invalidMachineSnapshot("engine is unavailable")
        }
        return try await controller.dial(
            containerID: machine.containerID,
            port: Self.publishedPortProxyPort
        )
    }

}
