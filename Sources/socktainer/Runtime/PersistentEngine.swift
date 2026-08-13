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

    private let controller: any EngineMachineControlling
    private let logger: Logger
    private var connection: GuestConnection?
    private var machine: EngineMachine?

    init(
        controller: any EngineMachineControlling,
        logger: Logger = Logger(label: "socktainer.engine")
    ) {
        self.controller = controller
        self.logger = logger
    }

    func readyConnection() async throws -> GuestConnection {
        if let connection { return connection }

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
        self.machine = snapshot
        self.connection = connection
        logger.info("persistent engine is ready", metadata: ["ip": "\(snapshot.ipAddress)"])
        return connection
    }

    func invalidateConnection() async {
        await connection?.close()
        connection = nil
    }

    func invalidateConnection(_ expected: GuestConnection) async {
        guard connection === expected else { return }
        await expected.close()
        connection = nil
    }

    func shutdown() async {
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

    func address() -> String? {
        machine?.ipAddress
    }

}
