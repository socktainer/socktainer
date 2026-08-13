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
    private let forwarder: any DirectTCPPortForwarding
    private var mappingIDsByContainer: [String: [String]] = [:]
    private var publishedBindingsByContainer: [String: [DockerRuntimePortBinding]] = [:]

    init(forwarder: any DirectTCPPortForwarding) {
        self.forwarder = forwarder
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
        var added: [DirectTCPPortMapping] = []
        do {
            for mapping in mappings {
                added.append(try await forwarder.add(mapping))
            }
        } catch {
            for mapping in added.reversed() {
                try? await forwarder.remove(id: mapping.id)
            }
            throw error
        }
        let published = zip(bindings, added).map { binding, mapping in
            DockerRuntimePortBinding(
                containerPort: binding.containerPort,
                proto: binding.proto,
                hostIP: binding.hostIP,
                hostPort: mapping.hostPort
            )
        }
        mappingIDsByContainer[containerID] = mappings.map(\.id)
        publishedBindingsByContainer[containerID] = published
        return published
    }

    func remove(containerID: String) async {
        let ids = mappingIDsByContainer.removeValue(forKey: containerID) ?? []
        publishedBindingsByContainer.removeValue(forKey: containerID)
        for id in ids {
            try? await forwarder.remove(id: id)
        }
    }

    func mappingIDs(containerID: String) -> [String] {
        mappingIDsByContainer[containerID] ?? []
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
            guard binding.proto.lowercased() == "tcp" else {
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
            let id = "\(containerID):tcp:\(hostAddress):\(hostPort)"
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
