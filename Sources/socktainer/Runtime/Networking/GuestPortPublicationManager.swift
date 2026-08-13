import Foundation
import Vapor

protocol DirectTCPPortForwarding: Sendable {
    func add(_ mapping: DirectTCPPortMapping) async throws -> DirectTCPPortMapping
    func remove(id: String) async throws
}

extension DirectTCPPortForwarder: DirectTCPPortForwarding {}

enum GuestPortPublicationError: Error, Equatable {
    case unsupportedProtocol(String)
    case invalidPort(Int)
    case guestPortCount(expected: Int, actual: Int)
}

/// Converts Docker port bindings into direct listeners for the persistent VM.
/// Publication is event-driven: the runtime publishes after a successful start
/// and removes all listeners after container deletion.
actor GuestPortPublicationManager {
    private enum Transport: Sendable { case tcp, udp }
    private struct ActiveMapping: Sendable {
        let id: String
        let transport: Transport
    }

    private let forwarder: any DirectTCPPortForwarding
    private let udpForwarder: (any DirectUDPPortForwarding)?
    private var mappingsByContainer: [String: [ActiveMapping]] = [:]
    private var publishedBindingsByContainer: [String: [DockerRuntimePortBinding]] = [:]

    init(
        forwarder: any DirectTCPPortForwarding,
        udpForwarder: (any DirectUDPPortForwarding)? = nil
    ) {
        self.forwarder = forwarder
        self.udpForwarder = udpForwarder
    }

    func publish(
        containerID: String,
        bindings: [DockerRuntimePortBinding],
        guestAddress: String,
        guestPorts: [Int]
    ) async throws -> [DockerRuntimePortBinding] {
        if let published = publishedBindingsByContainer[containerID] {
            return published
        }
        let mappings = try Self.mappings(
            containerID: containerID,
            bindings: bindings,
            guestAddress: guestAddress,
            guestPorts: guestPorts
        )
        var added: [(id: String, protocolName: String)] = []
        var published: [DockerRuntimePortBinding] = []
        do {
            for (binding, mapping) in zip(bindings, mappings) {
                if binding.proto.lowercased() == "udp" {
                    guard let udpForwarder else {
                        throw GuestPortPublicationError.unsupportedProtocol("udp")
                    }
                    let result = try await udpForwarder.add(
                        DirectUDPPortMapping(
                            id: mapping.id,
                            hostAddress: mapping.hostAddress,
                            hostPort: mapping.hostPort,
                            guestPort: mapping.guestPort
                        )
                    )
                    added.append((mapping.id, "udp"))
                    published.append(
                        DockerRuntimePortBinding(
                            containerPort: binding.containerPort, proto: binding.proto,
                            hostIP: binding.hostIP, hostPort: result.hostPort
                        )
                    )
                } else {
                    let result = try await forwarder.add(mapping)
                    added.append((mapping.id, "tcp"))
                    published.append(
                        DockerRuntimePortBinding(
                            containerPort: binding.containerPort, proto: binding.proto,
                            hostIP: binding.hostIP, hostPort: result.hostPort
                        )
                    )
                }
            }
        } catch {
            for mapping in added.reversed() {
                if mapping.protocolName == "udp" {
                    await udpForwarder?.remove(id: mapping.id)
                } else {
                    try? await forwarder.remove(id: mapping.id)
                }
            }
            throw error
        }
        mappingsByContainer[containerID] = zip(bindings, mappings).map { binding, mapping in
            ActiveMapping(
                id: mapping.id,
                transport: binding.proto.lowercased() == "udp" ? .udp : .tcp
            )
        }
        publishedBindingsByContainer[containerID] = published
        return published
    }

    func remove(containerID: String) async {
        let mappings = mappingsByContainer.removeValue(forKey: containerID) ?? []
        publishedBindingsByContainer.removeValue(forKey: containerID)
        for mapping in mappings {
            switch mapping.transport {
            case .udp:
                await udpForwarder?.remove(id: mapping.id)
            case .tcp:
                try? await forwarder.remove(id: mapping.id)
            }
        }
    }

    func mappingIDs(containerID: String) -> [String] {
        mappingsByContainer[containerID]?.map(\.id) ?? []
    }

    static func mappings(
        containerID: String,
        bindings: [DockerRuntimePortBinding],
        guestAddress: String,
        guestPorts: [Int]
    ) throws -> [DirectTCPPortMapping] {
        guard bindings.count == guestPorts.count else {
            throw GuestPortPublicationError.guestPortCount(
                expected: bindings.count,
                actual: guestPorts.count
            )
        }
        return try zip(bindings, guestPorts).map { binding, guestPort in
            let protocolName = binding.proto.lowercased()
            guard protocolName == "tcp" || protocolName == "udp" else {
                throw GuestPortPublicationError.unsupportedProtocol(binding.proto)
            }
            guard (1...65_535).contains(binding.containerPort) else {
                throw GuestPortPublicationError.invalidPort(binding.containerPort)
            }
            guard (1...65_535).contains(guestPort) else {
                throw GuestPortPublicationError.invalidPort(guestPort)
            }
            let hostPort = binding.hostPort ?? 0
            guard (0...65_535).contains(hostPort) else {
                throw GuestPortPublicationError.invalidPort(hostPort)
            }
            let hostAddress = binding.hostIP.isEmpty ? "0.0.0.0" : binding.hostIP
            let id = "\(containerID):\(protocolName):\(binding.containerPort):\(hostAddress):\(hostPort)"
            return DirectTCPPortMapping(
                id: id,
                hostAddress: hostAddress,
                hostPort: hostPort,
                guestAddress: guestAddress,
                guestPort: guestPort
            )
        }
    }
}

struct DirectTCPPortForwarderLifecycle: LifecycleHandler {
    let forwarder: DirectTCPPortForwarder

    func shutdownAsync(_ application: Application) async {
        await forwarder.shutdown()
    }
}
