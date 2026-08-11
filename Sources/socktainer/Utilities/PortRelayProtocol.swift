import Darwin
import NIOCore

/// Wire contract between the macOS listener and the per-network Linux relay.
///
/// The fixed-size preface is intentionally small and versioned. TCP bytes follow
/// it directly. UDP uses a sequence of UInt16-length-prefixed datagrams in each
/// direction so packet boundaries survive the Unix-stream/vsock transport.
enum PortRelayProtocol {
    static let magic: [UInt8] = [0x53, 0x4b, 0x54, 0x52]  // "SKTR"
    static let version: UInt8 = 1
    static let prefaceLength = 26
    // Maximum UDP payload defined by the IP/UDP headers, not merely the u16
    // framing capacity. The guest enforces the same bound.
    static let maximumDatagramLength = 65_507

    enum Transport: UInt8, Sendable {
        case tcp = 1
        case udp = 2
    }

    enum AddressFamily: UInt8, Sendable {
        case ipv4 = 4
        case ipv6 = 6
    }

    struct Destination: Equatable, Sendable {
        let address: String
        let port: UInt16
        let transport: Transport

        init(address: String, port: Int, transport: Transport) throws {
            guard port > 0, port <= Int(UInt16.max) else {
                throw ProtocolError.invalidPort(port)
            }
            guard Self.packedAddress(address) != nil else {
                throw ProtocolError.invalidAddress(address)
            }
            self.address = address
            self.port = UInt16(port)
            self.transport = transport
        }

        func writePreface(into buffer: inout ByteBuffer) throws {
            guard let packed = Self.packedAddress(address) else {
                throw ProtocolError.invalidAddress(address)
            }
            buffer.writeBytes(magic)
            buffer.writeInteger(version)
            buffer.writeInteger(transport.rawValue)
            buffer.writeInteger(packed.family.rawValue)
            buffer.writeInteger(UInt8(0))
            buffer.writeInteger(port, endianness: .big)
            buffer.writeBytes(packed.bytes)
            if packed.bytes.count < 16 {
                buffer.writeRepeatingByte(0, count: 16 - packed.bytes.count)
            }
        }

        private static func packedAddress(
            _ address: String
        ) -> (family: AddressFamily, bytes: [UInt8])? {
            var v4 = in_addr()
            if address.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
                return withUnsafeBytes(of: v4) { (.ipv4, Array($0)) }
            }
            var v6 = in6_addr()
            if address.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
                return withUnsafeBytes(of: v6) { (.ipv6, Array($0)) }
            }
            return nil
        }
    }

    enum ProtocolError: Error, Equatable {
        case invalidAddress(String)
        case invalidPort(Int)
        case datagramTooLarge(Int)
    }

    static func writeDatagram(_ payload: ByteBuffer, into buffer: inout ByteBuffer) throws {
        guard payload.readableBytes <= maximumDatagramLength else {
            throw ProtocolError.datagramTooLarge(payload.readableBytes)
        }
        buffer.writeInteger(UInt16(payload.readableBytes), endianness: .big)
        var payload = payload
        buffer.writeBuffer(&payload)
    }
}
