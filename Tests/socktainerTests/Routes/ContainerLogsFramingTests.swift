import Foundation
import NIOCore
import Testing

@testable import socktainer

/// Tests for `ContainerLogsRoute.processDockerLogFrames`, which must match the
/// container's TTY mode: non-TTY logs are multiplexed with Docker's 8-byte
/// stdcopy header, TTY logs are passed through raw.
@Suite("ContainerLogsRoute — log stream framing")
struct ContainerLogsFramingTests {

    private func collect(_ buffer: Data, ttyMode: Bool) throws -> ([UInt8], Data) {
        var out = ByteBuffer()
        let remainder = try ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: ttyMode) { frame in
            out.writeImmutableBuffer(frame)
        }
        return (Array(out.readableBytesView), remainder)
    }

    @Test("non-TTY logs are wrapped in the 8-byte stdcopy header")
    func nonTTYIsFramed() throws {
        let payload = Data("hello".utf8)
        let (bytes, remainder) = try collect(payload, ttyMode: false)

        // header: [stream=stdout(1), 0, 0, 0, size big-endian (4 bytes)] + payload
        #expect(bytes.count == 8 + payload.count)
        #expect(bytes[0] == 0x01)
        #expect(Array(bytes[1...3]) == [0, 0, 0])
        #expect(Array(bytes[4...7]) == [0, 0, 0, UInt8(payload.count)])
        #expect(Array(bytes[8...]) == Array(payload))
        #expect(remainder.isEmpty)
    }

    @Test("TTY logs are passed through raw, without any framing header")
    func ttyIsRaw() throws {
        let payload = Data("hello".utf8)
        let (bytes, remainder) = try collect(payload, ttyMode: true)

        #expect(bytes == Array(payload))
        #expect(remainder.isEmpty)
    }

    @Test("empty input produces no output in both modes")
    func emptyInput() throws {
        let (framed, r1) = try collect(Data(), ttyMode: false)
        let (raw, r2) = try collect(Data(), ttyMode: true)
        #expect(framed.isEmpty)
        #expect(raw.isEmpty)
        #expect(r1.isEmpty)
        #expect(r2.isEmpty)
    }
}
