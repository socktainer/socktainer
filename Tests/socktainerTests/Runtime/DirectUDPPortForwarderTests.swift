import Darwin
import Foundation
import Testing

@testable import socktainer

@Suite("Direct UDP port forwarder")
struct DirectUDPPortForwarderTests {
    @Test("allocates a port, forwards multiple datagrams, and removes idempotently")
    func forwardsAndRemoves() async throws {
        let forwarder = DirectUDPPortForwarder(dialer: FramedUDPGuestProxyDialer())
        let requested = DirectUDPPortMapping(
            id: "udp-echo", hostAddress: "127.0.0.1", hostPort: 0, guestPort: 42_000)

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

private struct FramedUDPGuestProxyDialer: GuestPortConnectionDialing {
    func dial() async throws -> FileHandle {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let client = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peer = descriptors[1]
        Task.detached {
            defer { _ = Darwin.close(peer) }
            var header = [UInt8](repeating: 0, count: 7)
            guard Darwin.read(peer, &header, header.count) == header.count,
                header.prefix(5) == [0x53, 0x54, 0x50, 0x31, 0x02]
            else { return }
            while true {
                var length = [UInt8](repeating: 0, count: 2)
                guard Darwin.read(peer, &length, length.count) == length.count else { return }
                let count = Int(length[0]) << 8 | Int(length[1])
                var payload = [UInt8](repeating: 0, count: count)
                guard Darwin.read(peer, &payload, count) == count else { return }
                _ = Darwin.write(peer, length, length.count)
                _ = Darwin.write(peer, payload, count)
            }
        }
        return client
    }
}
