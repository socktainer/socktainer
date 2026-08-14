import Darwin
import Foundation
import Vapor

enum GuestPortPublicationError: Error, Equatable {
    case unsupportedProtocol(String)
    case invalidPort(Int)
    case guestPortCount(expected: Int, actual: Int)
    case duplicateHostEndpoint(String)
    case dynamicPortRangeExhausted
    case publicationNotVisible(String)
    case invalidGVProxyResponse(String)
    case gvproxy(status: Int, message: String)
    case gvproxyResponseTooLarge
}

enum PublishedPortTransport: String, Codable, Hashable, Sendable {
    case tcp
    case udp
}

struct PublishedPortEndpoint: Codable, Hashable, Sendable {
    let local: String
    let remote: String
    let `protocol`: PublishedPortTransport
}

protocol PublishedPortControlling: Sendable {
    func guestIPv4() async throws -> String
    func all() async throws -> Set<PublishedPortEndpoint>
    func expose(_ endpoint: PublishedPortEndpoint) async throws
    func unexpose(_ endpoint: PublishedPortEndpoint) async throws
}

/// Controls gvproxy's generation-private HTTP interface over its Unix socket.
struct GVProxyPublishedPortController: PublishedPortControlling {
    typealias ReadyProvider = @Sendable () async throws -> RuntimeMachineReady

    private let ready: ReadyProvider

    init(ready: @escaping ReadyProvider) {
        self.ready = ready
    }

    func guestIPv4() async throws -> String {
        try await ready().guestIPv4
    }

    func all() async throws -> Set<PublishedPortEndpoint> {
        let response = try await request(method: "GET", path: "/services/forwarder/all", body: nil)
        do {
            return Set(try JSONDecoder().decode([PublishedPortEndpoint].self, from: response))
        } catch {
            throw GuestPortPublicationError.invalidGVProxyResponse(String(describing: error))
        }
    }

    func expose(_ endpoint: PublishedPortEndpoint) async throws {
        try await mutate(path: "/services/forwarder/expose", endpoint: endpoint)
    }

    func unexpose(_ endpoint: PublishedPortEndpoint) async throws {
        try await mutate(path: "/services/forwarder/unexpose", endpoint: endpoint)
    }

    private func mutate(path: String, endpoint: PublishedPortEndpoint) async throws {
        let body = try JSONEncoder().encode(endpoint)
        _ = try await request(method: "POST", path: path, body: body)
    }

    private func request(method: String, path: String, body: Data?) async throws -> Data {
        let snapshot = try await ready()
        return try await Task.detached {
            try Self.request(
                socket: snapshot.gvproxyAPI,
                method: method,
                path: path,
                body: body
            )
        }.value
    }

    private static func request(socket: URL, method: String, path: String, body: Data?) throws
        -> Data
    {
        let maximumResponseBytes = 1024 * 1024
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        guard
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            ) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard
                Darwin.setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    option,
                    &timeout,
                    socklen_t(MemoryLayout.size(ofValue: timeout))
                ) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socket.path.utf8)
        let capacity = withUnsafeBytes(of: address.sun_path) { $0.count }
        guard pathBytes.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let payload = body ?? Data()
        var request = Data(
            "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n"
                .utf8
        )
        request.append(payload)
        try writeAll(request, to: descriptor)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard response.count <= maximumResponseBytes - count else {
                throw GuestPortPublicationError.gvproxyResponseTooLarge
            }
            response.append(contentsOf: buffer.prefix(count))
        }
        return try parse(response)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
    }

    private static func parse(_ response: Data) throws -> Data {
        let marker = Data("\r\n\r\n".utf8)
        guard let boundary = response.range(of: marker),
            let headers = String(data: response[..<boundary.lowerBound], encoding: .utf8),
            let statusLine = headers.components(separatedBy: "\r\n").first,
            let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "")
        else {
            throw GuestPortPublicationError.invalidGVProxyResponse("invalid HTTP response")
        }
        let body = Data(response[boundary.upperBound...])
        guard (200..<300).contains(status) else {
            let message =
                String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "gvproxy request failed"
            throw GuestPortPublicationError.gvproxy(status: status, message: message)
        }
        if headers.lowercased().contains("transfer-encoding: chunked") {
            return try decodeChunked(body)
        }
        return body
    }

    private static func decodeChunked(_ body: Data) throws -> Data {
        let delimiter = Data("\r\n".utf8)
        var cursor = body.startIndex
        var result = Data()
        while true {
            guard let line = body[cursor...].range(of: delimiter),
                let text = String(data: body[cursor..<line.lowerBound], encoding: .ascii),
                let size = Int(text.split(separator: ";", maxSplits: 1)[0], radix: 16)
            else {
                throw GuestPortPublicationError.invalidGVProxyResponse("invalid chunked body")
            }
            cursor = line.upperBound
            if size == 0 { return result }
            guard let end = body.index(cursor, offsetBy: size, limitedBy: body.endIndex),
                body.distance(from: end, to: body.endIndex) >= delimiter.count,
                body[end..<body.index(end, offsetBy: delimiter.count)] == delimiter
            else {
                throw GuestPortPublicationError.invalidGVProxyResponse("truncated chunked body")
            }
            result.append(body[cursor..<end])
            cursor = body.index(end, offsetBy: delimiter.count)
        }
    }
}

/// Owns the complete published-port transaction. Callers do not manage gvproxy
/// endpoints, dynamic allocation, rollback, recovery, or shutdown ordering.
actor GuestPortPublicationManager {
    private struct Desired: Sendable {
        let binding: DockerRuntimePortBinding
        let guestPort: Int
    }

    private struct ContainerState: Sendable {
        let desired: [Desired]
        let bindings: [DockerRuntimePortBinding]
        var endpoints: [PublishedPortEndpoint]
    }

    private static let dynamicPorts = 49_152...65_535
    private static let maximumDynamicAttempts = 256

    private let controller: any PublishedPortControlling
    private var stateByContainer: [String: ContainerState] = [:]
    private var nextDynamicPort = Int.random(in: dynamicPorts)

    init(controller: any PublishedPortControlling) {
        self.controller = controller
    }

    func publish(
        containerID: String,
        bindings: [DockerRuntimePortBinding],
        guestPorts: [Int]
    ) async throws -> [DockerRuntimePortBinding] {
        let desired = try Self.validate(bindings: bindings, guestPorts: guestPorts)
        if var state = stateByContainer[containerID], state.desired.elementsEqual(desired, by: Self.sameDesired) {
            state.endpoints = try await restore(state)
            stateByContainer[containerID] = state
            return state.bindings
        }

        let guestIPv4 = try await controller.guestIPv4()
        var registry = try await controller.all()
        let previous = stateByContainer[containerID]
        var removedPrevious: [PublishedPortEndpoint] = []
        if let previous {
            do {
                for endpoint in previous.endpoints where registry.contains(endpoint) {
                    try await controller.unexpose(endpoint)
                    registry.remove(endpoint)
                    removedPrevious.append(endpoint)
                }
            } catch {
                for endpoint in removedPrevious { try? await controller.expose(endpoint) }
                throw error
            }
        }
        var added: [PublishedPortEndpoint] = []
        var realizedBindings: [DockerRuntimePortBinding] = []
        var realizedEndpoints: [PublishedPortEndpoint] = []
        do {
            for item in desired {
                let result = try await expose(item, guestIPv4: guestIPv4, registry: &registry)
                if result.added { added.append(result.endpoint) }
                realizedEndpoints.append(result.endpoint)
                realizedBindings.append(
                    DockerRuntimePortBinding(
                        containerPort: item.binding.containerPort,
                        proto: item.binding.proto,
                        hostIP: item.binding.hostIP,
                        hostPort: Self.port(from: result.endpoint.local)
                    )
                )
            }
            let visible = try await controller.all()
            for endpoint in realizedEndpoints where !visible.contains(endpoint) {
                throw GuestPortPublicationError.publicationNotVisible(endpoint.local)
            }
        } catch {
            for endpoint in added.reversed() { try? await controller.unexpose(endpoint) }
            for endpoint in removedPrevious { try? await controller.expose(endpoint) }
            throw error
        }

        stateByContainer[containerID] = ContainerState(
            desired: desired,
            bindings: realizedBindings,
            endpoints: realizedEndpoints
        )
        return realizedBindings
    }

    func reconcile() async throws {
        for containerID in stateByContainer.keys.sorted() {
            guard var state = stateByContainer[containerID] else { continue }
            state.endpoints = try await restore(state)
            stateByContainer[containerID] = state
        }
    }

    func remove(containerID: String) async throws {
        guard let state = stateByContainer[containerID] else { return }
        let visible = try await controller.all()
        for endpoint in state.endpoints where visible.contains(endpoint) {
            try await controller.unexpose(endpoint)
        }
        stateByContainer.removeValue(forKey: containerID)
    }

    func shutdown() async {
        for containerID in stateByContainer.keys.sorted() {
            try? await remove(containerID: containerID)
        }
    }

    func mappingIDs(containerID: String) -> [String] {
        stateByContainer[containerID]?.endpoints.map { "\($0.protocol.rawValue):\($0.local)" } ?? []
    }

    private func restore(_ state: ContainerState) async throws -> [PublishedPortEndpoint] {
        let guestIPv4 = try await controller.guestIPv4()
        let endpoints = zip(state.endpoints, state.desired).map { endpoint, desired in
            PublishedPortEndpoint(
                local: endpoint.local,
                remote: "\(guestIPv4):\(desired.guestPort)",
                protocol: endpoint.protocol
            )
        }
        var registry = try await controller.all()
        var added: [PublishedPortEndpoint] = []
        var removed: [PublishedPortEndpoint] = []
        do {
            for (old, endpoint) in zip(state.endpoints, endpoints) where !registry.contains(endpoint) {
                if old != endpoint, registry.contains(old) {
                    try await controller.unexpose(old)
                    registry.remove(old)
                    removed.append(old)
                }
                try Self.rejectConflict(endpoint, registry: registry)
                try await controller.expose(endpoint)
                registry.insert(endpoint)
                added.append(endpoint)
            }
            let visible = try await controller.all()
            for endpoint in endpoints where !visible.contains(endpoint) {
                throw GuestPortPublicationError.publicationNotVisible(endpoint.local)
            }
        } catch {
            for endpoint in added.reversed() { try? await controller.unexpose(endpoint) }
            for endpoint in removed { try? await controller.expose(endpoint) }
            throw error
        }
        return endpoints
    }

    private func expose(
        _ desired: Desired,
        guestIPv4: String,
        registry: inout Set<PublishedPortEndpoint>
    ) async throws -> (endpoint: PublishedPortEndpoint, added: Bool) {
        let transport = PublishedPortTransport(rawValue: desired.binding.proto.lowercased())!
        let host = desired.binding.hostIP.isEmpty ? "0.0.0.0" : desired.binding.hostIP
        let remote = "\(guestIPv4):\(desired.guestPort)"
        if let fixed = desired.binding.hostPort {
            let endpoint = PublishedPortEndpoint(
                local: "\(host):\(fixed)", remote: remote, protocol: transport
            )
            if registry.contains(endpoint) { return (endpoint, false) }
            try Self.rejectConflict(endpoint, registry: registry)
            try await controller.expose(endpoint)
            registry.insert(endpoint)
            return (endpoint, true)
        }

        for _ in 0..<Self.maximumDynamicAttempts {
            let port = takeDynamicPort()
            let endpoint = PublishedPortEndpoint(
                local: "\(host):\(port)", remote: remote, protocol: transport
            )
            if registry.contains(where: { $0.protocol == transport && $0.local == endpoint.local }) {
                continue
            }
            do {
                try await controller.expose(endpoint)
                registry.insert(endpoint)
                return (endpoint, true)
            } catch let error as GuestPortPublicationError where Self.isAddressInUse(error) {
                continue
            }
        }
        throw GuestPortPublicationError.dynamicPortRangeExhausted
    }

    private func takeDynamicPort() -> Int {
        let result = nextDynamicPort
        nextDynamicPort = result == Self.dynamicPorts.upperBound ? Self.dynamicPorts.lowerBound : result + 1
        return result
    }

    private static func isAddressInUse(_ error: GuestPortPublicationError) -> Bool {
        guard case .gvproxy(_, let message) = error else { return false }
        let value = message.lowercased()
        return value.contains("address already in use") || value.contains("proxy already running")
    }

    private static func rejectConflict(
        _ endpoint: PublishedPortEndpoint,
        registry: Set<PublishedPortEndpoint>
    ) throws {
        if registry.contains(where: { $0.protocol == endpoint.protocol && $0.local == endpoint.local }) {
            throw GuestPortPublicationError.duplicateHostEndpoint(
                "\(endpoint.protocol.rawValue)://\(endpoint.local)"
            )
        }
    }

    private static func port(from local: String) -> Int {
        Int(local.split(separator: ":").last!)!
    }

    private static func sameDesired(_ lhs: Desired, _ rhs: Desired) -> Bool {
        lhs.binding == rhs.binding && lhs.guestPort == rhs.guestPort
    }

    private static func validate(bindings: [DockerRuntimePortBinding], guestPorts: [Int]) throws
        -> [Desired]
    {
        guard bindings.count == guestPorts.count else {
            throw GuestPortPublicationError.guestPortCount(
                expected: bindings.count, actual: guestPorts.count
            )
        }
        return try zip(bindings, guestPorts).map { binding, guestPort in
            guard PublishedPortTransport(rawValue: binding.proto.lowercased()) != nil else {
                throw GuestPortPublicationError.unsupportedProtocol(binding.proto)
            }
            for port in [binding.containerPort, guestPort] where !(1...65_535).contains(port) {
                throw GuestPortPublicationError.invalidPort(port)
            }
            if let hostPort = binding.hostPort, !(1...65_535).contains(hostPort) {
                throw GuestPortPublicationError.invalidPort(hostPort)
            }
            return Desired(binding: binding, guestPort: guestPort)
        }
    }
}

struct GuestPortPublicationLifecycle: LifecycleHandler {
    let manager: GuestPortPublicationManager

    func shutdownAsync(_ application: Application) async {
        await manager.shutdown()
    }
}
