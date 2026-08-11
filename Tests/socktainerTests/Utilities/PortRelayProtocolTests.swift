import NIOCore
import Testing

@testable import socktainer

@Suite("Port relay protocol")
struct PortRelayProtocolTests {
    @Test("IPv4 TCP preface has stable network wire format")
    func ipv4Preface() throws {
        let destination = try PortRelayProtocol.Destination(
            address: "192.168.254.4",
            port: 5432,
            transport: .tcp
        )
        var buffer = ByteBuffer()
        try destination.writePreface(into: &buffer)

        #expect(buffer.readableBytes == PortRelayProtocol.prefaceLength)
        #expect(
            buffer.readBytes(length: buffer.readableBytes) == [
                0x53, 0x4b, 0x54, 0x52,
                2, 1, 4, 0,
                0x15, 0x38,
                192, 168, 254, 4,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ]
        )
    }

    @Test("IPv6 UDP preface preserves all address bytes")
    func ipv6Preface() throws {
        let destination = try PortRelayProtocol.Destination(
            address: "fd00::1234",
            port: 53,
            transport: .udp
        )
        var buffer = ByteBuffer()
        try destination.writePreface(into: &buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes)!

        #expect(bytes.count == 26)
        #expect(Array(bytes[0..<10]) == [0x53, 0x4b, 0x54, 0x52, 2, 2, 6, 0, 0, 53])
        #expect(Array(bytes[10..<26]) == [0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 0x34])
    }

    @Test("connect acknowledgement is buffered, validated, and consumed")
    func connectAcknowledgement() throws {
        for status in [
            PortRelayProtocol.ConnectStatus.ready,
            .connectionRefused,
            .routeUnavailable,
            .timedOut,
            .denied,
            .failed,
        ] {
            var partial = ByteBuffer(bytes: [0x53, 0x4b, 0x54, 0x41])
            #expect(try PortRelayProtocol.readAcknowledgement(from: &partial) == nil)
            partial.writeBytes([2, status.rawValue, 0, 0, 0xaa])
            #expect(try PortRelayProtocol.readAcknowledgement(from: &partial) == status)
            #expect(partial.readBytes(length: 1) == [0xaa])
        }
    }

    @Test("invalid connect acknowledgement fails closed")
    func invalidConnectAcknowledgement() {
        var buffer = ByteBuffer(bytes: [0x42, 0x41, 0x44, 0x21, 2, 0, 0, 0])
        #expect(throws: PortRelayProtocol.ProtocolError.invalidAcknowledgement) {
            _ = try PortRelayProtocol.readAcknowledgement(from: &buffer)
        }
    }

    @Test("invalid addresses and ports fail before listener publication")
    func invalidDestination() {
        #expect(throws: PortRelayProtocol.ProtocolError.invalidAddress("not-an-ip")) {
            _ = try PortRelayProtocol.Destination(address: "not-an-ip", port: 80, transport: .tcp)
        }
        #expect(throws: PortRelayProtocol.ProtocolError.invalidPort(0)) {
            _ = try PortRelayProtocol.Destination(address: "127.0.0.1", port: 0, transport: .tcp)
        }
        #expect(throws: PortRelayProtocol.ProtocolError.invalidPort(65_536)) {
            _ = try PortRelayProtocol.Destination(address: "127.0.0.1", port: 65_536, transport: .tcp)
        }
    }

    @Test("UDP frames retain datagram boundaries")
    func udpFrames() throws {
        let first = ByteBuffer(bytes: [1, 2, 3])
        let second = ByteBuffer(bytes: [4, 5])
        var wire = ByteBuffer()
        try PortRelayProtocol.writeDatagram(first, into: &wire)
        try PortRelayProtocol.writeDatagram(second, into: &wire)

        #expect(wire.readInteger(endianness: .big, as: UInt16.self) == 3)
        #expect(wire.readBytes(length: 3) == [1, 2, 3])
        #expect(wire.readInteger(endianness: .big, as: UInt16.self) == 2)
        #expect(wire.readBytes(length: 2) == [4, 5])
        #expect(wire.readableBytes == 0)
    }

    @Test("oversized UDP frame is rejected")
    func oversizedDatagram() {
        let payload = ByteBuffer(repeating: 0, count: PortRelayProtocol.maximumDatagramLength + 1)
        var wire = ByteBuffer()
        #expect(
            throws: PortRelayProtocol.ProtocolError.datagramTooLarge(
                PortRelayProtocol.maximumDatagramLength + 1
            )
        ) {
            try PortRelayProtocol.writeDatagram(payload, into: &wire)
        }
    }
}
