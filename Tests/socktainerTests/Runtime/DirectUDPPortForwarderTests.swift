import Darwin
import Foundation
import Testing

@testable import socktainer

@Suite("Direct UDP port forwarder")
struct DirectUDPPortForwarderTests {
    @Test("allocates a port, forwards multiple datagrams, and removes idempotently")
    func forwardsAndRemoves() async throws {
        let backend = try UDPEchoServer.start()
        defer { backend.close() }
        let forwarder = DirectUDPPortForwarder()
        let requested = DirectUDPPortMapping(
            id: "udp-echo", hostAddress: "127.0.0.1", hostPort: 0, guestPort: backend.port)

        let published = try await forwarder.add(requested)
        #expect(published.hostPort > 0)
        #expect(try Self.roundTrip(port: published.hostPort, payload: "first") == "first")
        #expect(try Self.roundTrip(port: published.hostPort, payload: "second") == "second")

        let duplicate = try await forwarder.add(requested)
        #expect(duplicate.hostPort == published.hostPort)
        await forwarder.remove(id: requested.id)
        await forwarder.remove(id: requested.id)
    }

    private static func roundTrip(port: Int, payload: String) throws -> String {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bytes = Array(payload.utf8)
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(
                        descriptor, buffer.baseAddress, buffer.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == bytes.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var response = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.recv(descriptor, &response, response.count, 0)
        guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return String(decoding: response.prefix(count), as: UTF8.self)
    }
}

private final class UDPEchoServer: @unchecked Sendable {
    let descriptor: Int32
    let port: Int
    private let task: Task<Void, Never>

    private init(descriptor: Int32, port: Int, task: Task<Void, Never>) {
        self.descriptor = descriptor
        self.port = port
        self.task = task
    }

    static func start() throws -> UDPEchoServer {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            _ = Darwin.close(descriptor)
            throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        let task = Task.detached {
            var buffer = [UInt8](repeating: 0, count: 65_535)
            while !Task.isCancelled {
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(descriptor, &buffer, buffer.count, 0, $0, &peerLength)
                    }
                }
                guard count > 0 else { return }
                _ = withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(descriptor, buffer, count, 0, $0, peerLength)
                    }
                }
            }
        }
        return UDPEchoServer(
            descriptor: descriptor,
            port: Int(UInt16(bigEndian: address.sin_port)),
            task: task
        )
    }

    func close() {
        _ = Darwin.close(descriptor)
        task.cancel()
    }
}
