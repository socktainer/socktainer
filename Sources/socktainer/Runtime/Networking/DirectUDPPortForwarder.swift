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
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: (NWConnection, NWConnection)] = [:]

    init(mapping: DirectUDPPortMapping) async throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(mapping.hostAddress),
            port: NWEndpoint.Port(rawValue: UInt16(mapping.hostPort))!
        )
        listener = try NWListener(using: parameters)
        queue = DispatchQueue(label: "socktainer.udp.\(mapping.id)")
        let guest = NWEndpoint.Host("127.0.0.1")
        let guestPort = NWEndpoint.Port(rawValue: UInt16(mapping.guestPort))!
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
                let backend = NWConnection(host: guest, port: guestPort, using: .udp)
                let identifier = ObjectIdentifier(client)
                self.lock.withLock { self.connections[identifier] = (client, backend) }
                client.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state { self?.remove(identifier) }
                }
                client.start(queue: self.queue)
                backend.start(queue: self.queue)
                self.receiveFromClient(client: client, backend: backend, identifier: identifier)
                self.receiveFromBackend(client: client, backend: backend, identifier: identifier)
            }
            listener.start(queue: queue)
        }
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    func close() {
        listener.cancel()
        let current = lock.withLock { () -> [(NWConnection, NWConnection)] in
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        for (client, backend) in current {
            client.cancel()
            backend.cancel()
        }
    }

    private func receiveFromClient(
        client: NWConnection,
        backend: NWConnection,
        identifier: ObjectIdentifier
    ) {
        client.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                self?.remove(identifier)
                return
            }
            backend.send(
                content: data,
                completion: .contentProcessed { error in
                    guard error == nil else {
                        self.remove(identifier)
                        return
                    }
                    self.receiveFromClient(
                        client: client, backend: backend, identifier: identifier)
                })
        }
    }

    private func receiveFromBackend(
        client: NWConnection,
        backend: NWConnection,
        identifier: ObjectIdentifier
    ) {
        backend.receiveMessage { [weak self] response, context, _, error in
            guard let self, error == nil, let response else {
                self?.remove(identifier)
                return
            }
            client.send(
                content: response,
                contentContext: context ?? .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    guard error == nil else {
                        self.remove(identifier)
                        return
                    }
                    self.receiveFromBackend(
                        client: client, backend: backend, identifier: identifier)
                })
        }
    }

    private func remove(_ identifier: ObjectIdentifier) {
        let pair = lock.withLock { connections.removeValue(forKey: identifier) }
        pair?.0.cancel()
        pair?.1.cancel()
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

    func add(_ mapping: DirectUDPPortMapping) async throws -> DirectUDPPortMapping {
        if let listener = active[mapping.id] {
            return DirectUDPPortMapping(
                id: mapping.id,
                hostAddress: mapping.hostAddress,
                hostPort: listener.port,
                guestPort: mapping.guestPort
            )
        }
        let listener = try await UDPListener(mapping: mapping)
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
