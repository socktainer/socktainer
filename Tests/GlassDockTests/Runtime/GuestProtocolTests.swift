import Foundation
import Testing

@testable import GlassDock

@Suite("Guest protocol framing")
struct GuestProtocolTests {
    @Test("decodes fragmented and coalesced frames")
    func fragmentationAndCoalescing() throws {
        let first = GuestFrame(
            id: 1,
            kind: .request,
            method: "ping",
            payload: .object(["version": .number(1)]),
            stream: nil,
            data: nil,
            error: nil,
            exitCode: nil
        )
        let second = GuestFrame(
            id: 2,
            kind: .stream,
            method: nil,
            payload: nil,
            stream: .stdout,
            data: Data("ok".utf8),
            error: nil,
            exitCode: nil
        )
        let bytes = try GuestFrameCodec.encode(first) + GuestFrameCodec.encode(second)
        var codec = GuestFrameCodec()
        var decoded: [GuestFrame] = []
        for byte in bytes {
            decoded += try codec.append(Data([byte]))
        }
        try codec.finish()
        #expect(decoded == [first, second])
    }

    @Test("rejects an oversized length before buffering the payload")
    func oversizedFrame() throws {
        let length = UInt32(GuestFrame.maximumPayloadSize + 1)
        let header = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        var codec = GuestFrameCodec()
        #expect(throws: GuestFrameCodecError.frameTooLarge(Int(length))) {
            _ = try codec.append(header)
        }
    }

    @Test("detects a truncated final frame")
    func truncatedFrame() throws {
        var codec = GuestFrameCodec()
        _ = try codec.append(Data([0, 0, 0, 2, 0]))
        #expect(throws: GuestFrameCodecError.truncatedFrame) {
            try codec.finish()
        }
    }

    @Test("rejects a zero-length frame like the guest decoder")
    func zeroLengthFrame() throws {
        var codec = GuestFrameCodec()
        #expect(
            throws: GuestFrameCodecError.invalidEnvelope("frame length must be nonzero")
        ) {
            _ = try codec.append(Data([0, 0, 0, 0]))
        }
    }
}
