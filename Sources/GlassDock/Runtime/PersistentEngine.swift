import Foundation
import Logging

enum PersistentEngineError: Error, Equatable {
    case invalidMachineSnapshot(String)
    case guestReadinessTimedOut
}

/// Owns the application-facing lifecycle of the one persistent custom VM.
/// Callers obtain one ready multiplexed guest connection and do not learn VMM
/// provisioning or device details.
actor PersistentEngine {
    static let guestPort: UInt32 = 1025

    private let machine: any EngineMachineHosting
    private let logger: Logger
    private let guestReadinessTimeout: Duration
    private let isConnectionTerminal: @Sendable (GuestConnection) async -> Bool
    private var connection: GuestConnection?
    private var readyMachine: RuntimeMachineReady?
    private struct Readiness {
        let token: UUID
        let task: Task<(GuestConnection, RuntimeMachineReady), Error>
    }
    private var readiness: Readiness?
    private var requiresMachineRestart = false

    init(
        machine: any EngineMachineHosting,
        logger: Logger = Logger(label: "glassdock.engine"),
        guestReadinessTimeout: Duration = .seconds(10),
        isConnectionTerminal: @escaping @Sendable (GuestConnection) async -> Bool = PersistentEngine.connectionIsTerminal
    ) {
        self.machine = machine
        self.logger = logger
        self.guestReadinessTimeout = guestReadinessTimeout
        self.isConnectionTerminal = isConnectionTerminal
    }

    func readyConnection() async throws -> GuestConnection {
        while let candidate = connection {
            let terminal = await isConnectionTerminal(candidate)
            guard connection === candidate else { continue }
            if !terminal { return candidate }
            self.connection = nil
            readyMachine = nil
            requiresMachineRestart = true
        }
        let current: Readiness
        if let readiness {
            current = readiness
        } else {
            let restartMachine = requiresMachineRestart
            requiresMachineRestart = false
            current = Readiness(
                token: UUID(),
                task: Task { try await self.establishConnection(restartMachine: restartMachine) }
            )
            readiness = current
        }
        do {
            let (connection, snapshot) = try await current.task.value
            if readiness?.token == current.token { readiness = nil }
            readyMachine = snapshot
            self.connection = connection
            return connection
        } catch {
            if readiness?.token == current.token { readiness = nil }
            throw error
        }
    }

    private nonisolated static func connectionIsTerminal(_ connection: GuestConnection) async
        -> Bool
    {
        await connection.isTerminal()
    }

    private func establishConnection(restartMachine: Bool) async throws
        -> (GuestConnection, RuntimeMachineReady)
    {
        if restartMachine {
            try await machine.stop()
        }
        let snapshot = try await machine.start()
        do {
            let connection = try await waitForGuestReadiness()
            logger.info("persistent engine is ready", metadata: ["ip": "\(snapshot.guestIPv4)"])
            return (connection, snapshot)
        } catch {
            try? await machine.stop()
            throw error
        }
    }

    /// Waits until the already-started guest can complete the control protocol
    /// handshake. libkrun publishes its host listener before the guest binds the
    /// corresponding vsock port, so socket existence alone is not readiness.
    /// This loop retries only the read-only startup ping. It never replays a
    /// Docker operation.
    private func waitForGuestReadiness() async throws -> GuestConnection {
        let deadline = ContinuousClock.now + guestReadinessTimeout
        var delay = Duration.milliseconds(1)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var connection: GuestConnection?
            do {
                let candidate = try await GuestConnection.connect {
                    try await self.machine.connect(to: Self.guestPort)
                }
                connection = candidate
                let response = try await candidate.request(method: "ping", payload: .object([:]))
                guard response.kind == .response,
                    response.payload == .object(["ok": .bool(true)])
                else {
                    await candidate.close()
                    throw PersistentEngineError.invalidMachineSnapshot(
                        "guest ping returned an invalid response"
                    )
                }
                return candidate
            } catch let error as PersistentEngineError {
                await connection?.close()
                throw error
            } catch {
                await connection?.close()
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { break }
                try await Task.sleep(for: min(delay, remaining))
                delay = min(delay * 2, .milliseconds(25))
            }
        }
        throw PersistentEngineError.guestReadinessTimedOut
    }

    func invalidateConnection() async {
        await connection?.close()
        connection = nil
        requiresMachineRestart = true
        readiness?.task.cancel()
        readiness = nil
    }

    func invalidateConnection(_ expected: GuestConnection) async {
        guard connection === expected else { return }
        await expected.close()
        connection = nil
        requiresMachineRestart = true
    }

    func shutdown() async {
        if let connection {
            _ = try? await connection.request(method: "engine.sync", payload: .object([:]))
            await connection.close()
        }
        connection = nil
        readyMachine = nil
        do {
            try await machine.stop()
        } catch {
            logger.error("failed to stop persistent engine", metadata: ["error": "\(error)"])
        }
    }

    func address() -> String? {
        readyMachine?.guestIPv4
    }

    func hostGatewayAddress() -> String? {
        readyMachine?.hostGatewayIPv4
    }

}
