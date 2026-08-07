import Foundation
import Vapor

/// Couples a potentially silent Docker streaming operation to its HTTP
/// channel. Progress and newline liveness probes share one serialized writer;
/// any channel write failure cancels the operation task, while ordinary
/// operation failures remain available to the route for Docker JSON framing.
enum DisconnectCoupledResponseStream {
    static let defaultHeartbeatInterval: Duration = .seconds(1)

    enum ProducerError: Error {
        case clientDisconnected
    }

    static func run(
        writer: any AsyncBodyStreamWriter,
        heartbeatInterval: Duration = defaultHeartbeatInterval,
        operation:
            @Sendable @escaping (
                any AsyncBodyStreamWriter
            ) async throws -> Void
    ) async throws {
        let coupledWriter = DisconnectDetectingWriter(writer: writer)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation(coupledWriter)
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: heartbeatInterval)
                    try Task.checkCancellation()
                    // Newline is insignificant whitespace in Docker's stream
                    // of JSON objects, so a probe never invents an event.
                    try await coupledWriter.write(
                        .buffer(ByteBuffer(string: "\n"))
                    )
                }
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private struct DisconnectDetectingWriter: AsyncBodyStreamWriter {
        let writer: any AsyncBodyStreamWriter
        let admission = WriteAdmission()

        func write(_ result: BodyStreamResult) async throws {
            let permit = try await admission.acquire()
            do {
                try Task.checkCancellation()
                try await writer.write(result)
                await admission.release(permit, disconnected: false)
            } catch is CancellationError {
                await admission.release(permit, disconnected: false)
                throw CancellationError()
            } catch {
                await admission.release(permit, disconnected: true)
                throw ProducerError.clientDisconnected
            }
        }
    }

    /// Actor methods are reentrant across `await`, so an actor wrapper alone
    /// does not serialize writes. This explicit FIFO admission keeps progress
    /// and heartbeat frames from overlapping on Vapor's response writer.
    private actor WriteAdmission {
        private var nextID: UInt64 = 0
        private var owner: UInt64?
        private var order: [UInt64] = []
        private var nextWaiterIndex = 0
        private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        private var disconnected = false

        func acquire() async throws -> UInt64 {
            try Task.checkCancellation()
            guard !disconnected else {
                throw ProducerError.clientDisconnected
            }

            let id = nextID
            nextID &+= 1
            if owner == nil {
                owner = id
                return id
            }

            await withCheckedContinuation { continuation in
                order.append(id)
                waiters[id] = continuation
            }
            if Task.isCancelled {
                release(id, disconnected: false)
                throw CancellationError()
            }
            guard !disconnected else {
                throw ProducerError.clientDisconnected
            }
            return id
        }

        func release(_ id: UInt64, disconnected failed: Bool) {
            guard owner == id else { return }
            if failed {
                disconnected = true
                owner = nil
                let pending = Array(waiters.values)
                waiters.removeAll(keepingCapacity: false)
                order.removeAll(keepingCapacity: false)
                nextWaiterIndex = 0
                for waiter in pending {
                    waiter.resume()
                }
                return
            }

            while nextWaiterIndex < order.count {
                let next = order[nextWaiterIndex]
                nextWaiterIndex += 1
                guard let waiter = waiters.removeValue(forKey: next) else {
                    continue
                }
                owner = next
                waiter.resume()
                return
            }
            owner = nil
            order.removeAll(keepingCapacity: true)
            nextWaiterIndex = 0
        }
    }
}
