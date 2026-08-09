import ContainerResource
import ContainerizationExtras
import Darwin
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("Dynamic port allocator")
struct DynamicPortAllocatorTests {
    @Test("reserves dynamic TCP and UDP ports and releases them")
    func reservesAndReleasesPorts() async throws {
        let allocator = DynamicPortAllocator(logger: Logger(label: "socktainer.tests.dynamic-ports"))
        let mappings = try [
            PublishPort(
                hostAddress: IPAddress("127.0.0.1"),
                hostPort: 0,
                containerPort: 5432,
                proto: .tcp,
                count: 1
            ),
            PublishPort(
                hostAddress: IPAddress("127.0.0.1"),
                hostPort: 0,
                containerPort: 5353,
                proto: .udp,
                count: 1
            ),
        ]
        let reservation = try await allocator.reserveDynamicPorts(mappings)
        let ports = reservation.ports
        #expect(ports.allSatisfy { $0.hostPort != 0 })
        #expect(Set(ports.map(\.hostPort)).count == ports.count)

        let nativeID = "dynamic-port-test-\(UUID().uuidString)"
        await allocator.commit(reservation, nativeID: nativeID)
        #expect(!Self.canBindTCP(port: try #require(ports[0].hostPort)))
        await allocator.release(nativeID: nativeID)
        #expect(Self.canBindTCP(port: try #require(ports[0].hostPort)))
        await allocator.shutdown()
    }

    @Test("holds a contiguous range while create transitions to start")
    func reservesContiguousRange() async throws {
        let allocator = DynamicPortAllocator(logger: Logger(label: "socktainer.tests.dynamic-range"))
        let mapping = try PublishPort(
            hostAddress: IPAddress("127.0.0.1"),
            hostPort: 0,
            containerPort: 8000,
            proto: .tcp,
            count: 3
        )
        let reservation = try await allocator.reserveDynamicPorts([mapping])
        let base = try #require(reservation.ports.first?.hostPort)
        for offset in 0..<3 {
            #expect(!Self.canBindTCP(port: base + UInt16(offset)))
        }
        await allocator.cancel(reservation)
        for offset in 0..<3 {
            #expect(Self.canBindTCP(port: base + UInt16(offset)))
        }
        await allocator.shutdown()
    }

    private static func canBindTCP(port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
