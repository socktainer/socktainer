import Logging
import NIOCore
import SocketForwarder

/// A direct host TCP publication. The backend is an address in the persistent
/// engine VM. No relay VM or intermediate Unix socket is involved.
struct DirectTCPPortMapping: Hashable, Sendable {
    let id: String
    let hostAddress: String
    let hostPort: Int
    let guestAddress: String
    let guestPort: Int

    init(
        id: String,
        hostAddress: String,
        hostPort: Int,
        guestAddress: String,
        guestPort: Int
    ) {
        self.id = id
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestAddress = guestAddress
        self.guestPort = guestPort
    }
}

enum DirectTCPPortForwarderError: Error, Equatable {
    case duplicateIdentifier(String)
    case duplicateHostEndpoint(address: String, port: Int)
    case reconcileFailed(String, rollbackFailures: [String])
}

protocol DirectTCPListenerHandle: Sendable {
    var boundPort: Int { get }
    func close() async throws
}

protocol DirectTCPListenerFactory: Sendable {
    func start(_ mapping: DirectTCPPortMapping) async throws -> any DirectTCPListenerHandle
}

private struct NIOListenerHandle: DirectTCPListenerHandle {
    let result: SocketForwarderResult

    var boundPort: Int { result.proxyAddress?.port ?? 0 }

    func close() async throws {
        result.close()
    }
}

private struct NativeVmnetListenerHandle: DirectTCPListenerHandle {
    let boundPort: Int
    func close() async throws {}
}

private struct NIODirectTCPListenerFactory: DirectTCPListenerFactory {
    let eventLoopGroup: any EventLoopGroup
    let logger: Logger

    func start(_ mapping: DirectTCPPortMapping) async throws -> any DirectTCPListenerHandle {
        if mapping.hostPort == 0,
            NativeVmnetPortRange.ports.contains(mapping.guestPort)
        {
            return NativeVmnetListenerHandle(boundPort: mapping.guestPort)
        }
        let host = try SocketAddress(
            ipAddress: mapping.hostAddress,
            port: mapping.hostPort
        )
        // A custom vmnet shared network does not route direct host connections
        // to its guest address. Connect explicit host listeners to the
        // preallocated vmnet loopback forwarding rule instead.
        let backendAddress =
            NativeVmnetPortRange.ports.contains(mapping.guestPort)
            ? "127.0.0.1" : mapping.guestAddress
        let guest = try SocketAddress(
            ipAddress: backendAddress,
            port: mapping.guestPort
        )
        let result = try await TCPForwarder(
            proxyAddress: host,
            serverAddress: guest,
            eventLoopGroup: eventLoopGroup,
            connectTimeout: .seconds(1),
            log: logger
        ).run().get()
        return NIOListenerHandle(result: result)
    }
}

/// Owns direct host listeners for the persistent engine VM.
///
/// The guest agent can call `add`, `remove`, or `reconcile` when containerd
/// emits lifecycle events. Reconciliation is idempotent. If an update fails,
/// the actor removes listeners added by that update and restores listeners it
/// removed before it reports the error.
actor DirectTCPPortForwarder {
    private struct ActivePublication {
        let mapping: DirectTCPPortMapping
        let listener: any DirectTCPListenerHandle
    }

    private struct HostEndpoint: Hashable {
        let address: String
        let port: Int
    }

    private let factory: any DirectTCPListenerFactory
    private let logger: Logger
    private var active: [String: ActivePublication] = [:]

    init(eventLoopGroup: any EventLoopGroup, logger: Logger) {
        self.factory = NIODirectTCPListenerFactory(
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger
    }

    init(factory: any DirectTCPListenerFactory, logger: Logger) {
        self.factory = factory
        self.logger = logger
    }

    @discardableResult
    func add(_ mapping: DirectTCPPortMapping) async throws -> DirectTCPPortMapping {
        if active[mapping.id]?.mapping == mapping {
            return mapping
        }
        var desired = active.values.map(\.mapping)
        desired.removeAll { $0.id == mapping.id }
        desired.append(mapping)
        try await reconcile(desired)
        return active[mapping.id]?.mapping ?? mapping
    }

    func remove(id: String) async throws {
        guard let publication = active.removeValue(forKey: id) else {
            return
        }
        do {
            try await publication.listener.close()
        } catch {
            active[id] = publication
            throw error
        }
    }

    func reconcile(_ mappings: [DirectTCPPortMapping]) async throws {
        let desired = try Self.validate(mappings)
        let removed = active.values
            .filter { desired[$0.mapping.id] != $0.mapping }
            .sorted { $0.mapping.id < $1.mapping.id }
        let additions = desired.values
            .filter { active[$0.id]?.mapping != $0 }
            .sorted { $0.id < $1.id }

        var removedClosed: [ActivePublication] = []
        for publication in removed {
            do {
                try await publication.listener.close()
                active.removeValue(forKey: publication.mapping.id)
                removedClosed.append(publication)
            } catch {
                let rollbackFailures = await restore(removedClosed)
                throw DirectTCPPortForwarderError.reconcileFailed(
                    String(describing: error),
                    rollbackFailures: rollbackFailures
                )
            }
        }

        var added: [ActivePublication] = []
        do {
            for mapping in additions {
                let listener = try await factory.start(mapping)
                let realized = DirectTCPPortMapping(
                    id: mapping.id,
                    hostAddress: mapping.hostAddress,
                    hostPort: listener.boundPort,
                    guestAddress: mapping.guestAddress,
                    guestPort: mapping.guestPort
                )
                let publication = ActivePublication(mapping: realized, listener: listener)
                active[mapping.id] = publication
                added.append(publication)
            }
        } catch {
            var rollbackFailures: [String] = []
            for publication in added.reversed() {
                do {
                    try await publication.listener.close()
                    active.removeValue(forKey: publication.mapping.id)
                } catch {
                    rollbackFailures.append(String(describing: error))
                }
            }
            rollbackFailures.append(contentsOf: await restore(removedClosed))
            logger.error(
                "Direct TCP publication reconciliation failed",
                metadata: ["error": "\(error)", "rollbackFailures": "\(rollbackFailures)"]
            )
            throw DirectTCPPortForwarderError.reconcileFailed(
                String(describing: error),
                rollbackFailures: rollbackFailures
            )
        }
    }

    func shutdown() async {
        let publications = active.values.sorted { $0.mapping.id < $1.mapping.id }
        active.removeAll()
        for publication in publications {
            do {
                try await publication.listener.close()
            } catch {
                logger.warning(
                    "Failed to close direct TCP publication",
                    metadata: ["id": "\(publication.mapping.id)", "error": "\(error)"]
                )
            }
        }
    }

    func mappings() -> [DirectTCPPortMapping] {
        active.values.map(\.mapping).sorted { $0.id < $1.id }
    }

    private func restore(_ publications: [ActivePublication]) async -> [String] {
        var failures: [String] = []
        for publication in publications {
            do {
                let listener = try await factory.start(publication.mapping)
                let restored = ActivePublication(
                    mapping: DirectTCPPortMapping(
                        id: publication.mapping.id,
                        hostAddress: publication.mapping.hostAddress,
                        hostPort: listener.boundPort,
                        guestAddress: publication.mapping.guestAddress,
                        guestPort: publication.mapping.guestPort
                    ),
                    listener: listener
                )
                active[publication.mapping.id] = restored
            } catch {
                failures.append(String(describing: error))
            }
        }
        return failures
    }

    private static func validate(
        _ mappings: [DirectTCPPortMapping]
    ) throws -> [String: DirectTCPPortMapping] {
        var desired: [String: DirectTCPPortMapping] = [:]
        var endpoints: [HostEndpoint: String] = [:]
        for mapping in mappings {
            guard desired[mapping.id] == nil else {
                throw DirectTCPPortForwarderError.duplicateIdentifier(mapping.id)
            }
            let endpoint = HostEndpoint(
                address: mapping.hostAddress,
                port: mapping.hostPort
            )
            if endpoints[endpoint] != nil {
                throw DirectTCPPortForwarderError.duplicateHostEndpoint(
                    address: endpoint.address,
                    port: endpoint.port
                )
            }
            desired[mapping.id] = mapping
            endpoints[endpoint] = mapping.id
        }
        return desired
    }
}
