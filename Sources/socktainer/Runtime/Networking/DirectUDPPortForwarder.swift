import Darwin
import Foundation
import Network
import Vapor

struct DirectUDPPortMapping: Hashable, Sendable {
    let id: String
    let hostAddress: String
    let hostPort: Int
    let guestPort: Int
}

protocol DirectUDPPortForwarding: Sendable {
    func add(_ mapping: DirectUDPPortMapping) async throws -> DirectUDPPortMapping
    func remove(id: String) async
}

private final class UDPListener: @unchecked Sendable {
    let listener: NWListener
    let queue: DispatchQueue
    private let mapping: DirectUDPPortMapping
    private let dialer: any GuestPortConnectionDialing
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: FramedUDPConnection] = [:]

    init(mapping: DirectUDPPortMapping, dialer: any GuestPortConnectionDialing) async throws {
        self.mapping = mapping
        self.dialer = dialer
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(mapping.hostAddress),
            port: NWEndpoint.Port(rawValue: UInt16(mapping.hostPort))!
        )
        listener = try NWListener(using: parameters)
        queue = DispatchQueue(label: "socktainer.udp.\(mapping.id)")
        try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume() }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] client in
                guard let self else { return }
                client.start(queue: self.queue)
                Task { await self.start(client) }
            }
            listener.start(queue: queue)
        }
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    func close() {
        listener.cancel()
        let current = lock.withLock { () -> [FramedUDPConnection] in
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        for connection in current { connection.close() }
    }

    private func start(_ client: NWConnection) async {
        let identifier = ObjectIdentifier(client)
        do {
            let handle = try await dialer.dial()
            let connection = try FramedUDPConnection(
                client: client,
                handle: handle,
                guestPort: UInt16(mapping.guestPort),
                onClose: { [weak self] in self?.remove(identifier) }
            )
            lock.withLock { connections[identifier] = connection }
            client.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.remove(identifier) }
            }
            receiveFromClient(connection, identifier: identifier)
        } catch {
            client.cancel()
        }
    }

    private func receiveFromClient(_ connection: FramedUDPConnection, identifier: ObjectIdentifier) {
        let client = connection.client
        client.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                self?.remove(identifier)
                return
            }
            guard connection.send(data) else {
                self.remove(identifier)
                return
            }
            self.receiveFromClient(connection, identifier: identifier)
        }
    }

    private func remove(_ identifier: ObjectIdentifier) {
        lock.withLock { connections.removeValue(forKey: identifier) }?.close()
    }
}

private final class FramedUDPConnection: @unchecked Sendable {
    let client: NWConnection
    private let handle: FileHandle
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false

    init(
        client: NWConnection,
        handle: FileHandle,
        guestPort: UInt16,
        onClose: @escaping @Sendable () -> Void
    ) throws {
        self.client = client
        self.handle = handle
        self.onClose = onClose
        var header = Data([0x53, 0x54, 0x50, 0x31, 0x02])
        header.append(UInt8(guestPort >> 8))
        header.append(UInt8(guestPort & 0xff))
        try handle.write(contentsOf: header)
        Task.detached { [weak self] in self?.readResponses() }
    }

    func send(_ payload: Data) -> Bool {
        guard payload.count <= 65_507, !lock.withLock({ closed }) else { return false }
        var frame = Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        frame.append(payload)
        do {
            try handle.write(contentsOf: frame)
            return true
        } catch {
            return false
        }
    }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        client.cancel()
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
    }

    private func readResponses() {
        defer {
            try? handle.close()
            onClose()
        }
        while true {
            guard let length = readExactly(2) else { return }
            let count = Int(length[0]) << 8 | Int(length[1])
            guard let payload = readExactly(count) else { return }
            client.send(
                content: payload,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() }
                }
            )
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var result = Data()
        while result.count < count {
            guard let chunk = try? handle.read(upToCount: count - result.count),
                !chunk.isEmpty
            else { return nil }
            result.append(chunk)
        }
        return result
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}

actor DirectUDPPortForwarder: DirectUDPPortForwarding {
    private var active: [String: UDPListener] = [:]
    private let dialer: any GuestPortConnectionDialing

    init(engine: PersistentEngine) {
        self.dialer = PersistentEngineGuestPortDialer(engine: engine)
    }

    init(dialer: any GuestPortConnectionDialing) {
        self.dialer = dialer
    }

    func add(_ mapping: DirectUDPPortMapping) async throws -> DirectUDPPortMapping {
        if let listener = active[mapping.id] {
            return DirectUDPPortMapping(
                id: mapping.id,
                hostAddress: mapping.hostAddress,
                hostPort: listener.port,
                guestPort: mapping.guestPort
            )
        }
        let listener = try await UDPListener(mapping: mapping, dialer: dialer)
        active[mapping.id] = listener
        return DirectUDPPortMapping(
            id: mapping.id,
            hostAddress: mapping.hostAddress,
            hostPort: listener.port,
            guestPort: mapping.guestPort
        )
    }

    func remove(id: String) {
        active.removeValue(forKey: id)?.close()
    }

    func shutdown() {
        let listeners = active.values
        active.removeAll()
        for listener in listeners { listener.close() }
    }
}

struct DirectUDPPortForwarderLifecycle: LifecycleHandler {
    let forwarder: DirectUDPPortForwarder
    func shutdownAsync(_ application: Application) async {
        await forwarder.shutdown()
    }
}
