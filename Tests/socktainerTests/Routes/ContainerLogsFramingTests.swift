import Foundation
import NIOCore
import Testing

@testable import socktainer

/// Tests for `ContainerLogsRoute.processDockerLogFrames`, which must match the
/// container's TTY mode: non-TTY logs are multiplexed with Docker's 8-byte
/// stdcopy header, TTY logs are passed through raw.
@Suite("ContainerLogsRoute — log stream framing")
struct ContainerLogsFramingTests {

    private func collect(_ buffer: Data, ttyMode: Bool, timestamps: Bool = false) -> ([UInt8], Data) {
        var out = ByteBuffer()
        let remainder = ContainerLogsRoute.processDockerLogFrames(from: buffer, ttyMode: ttyMode, timestamps: timestamps) { frame in
            out.writeImmutableBuffer(frame)
        }
        return (Array(out.readableBytesView), remainder)
    }

    @Test("non-TTY logs are wrapped in the 8-byte stdcopy header")
    func nonTTYIsFramed() throws {
        let payload = Data("hello".utf8)
        let (bytes, remainder) = collect(payload, ttyMode: false)

        // header: [stream=stdout(1), 0, 0, 0, size big-endian (4 bytes)] + payload
        #expect(bytes.count == 8 + payload.count)
        #expect(bytes[0] == 0x01)
        #expect(Array(bytes[1...3]) == [0, 0, 0])
        #expect(Array(bytes[4...7]) == [0, 0, 0, UInt8(payload.count)])
        #expect(Array(bytes[8...]) == Array(payload))
        #expect(remainder.isEmpty)
    }

    @Test("non-TTY length field uses all four big-endian header bytes (payload > 255B)")
    func nonTTYLengthUsesAllHeaderBytes() throws {
        let payload = Data(repeating: 0x61, count: 300)  // 300 = 0x0000012C
        let (bytes, remainder) = collect(payload, ttyMode: false)

        // The sibling test covers the header shape for a small payload; this one
        // exists to verify the upper length bytes, so it asserts all four.
        #expect(Array(bytes[4...7]) == [0, 0, 1, 44])  // 300 big-endian = 0x00 0x00 0x01 0x2C
        #expect(Array(bytes[8...]) == Array(payload))
        #expect(remainder.isEmpty)
    }

    @Test("TTY logs are passed through raw, without any framing header")
    func ttyIsRaw() throws {
        let payload = Data("hello".utf8)
        let (bytes, remainder) = collect(payload, ttyMode: true)

        #expect(bytes == Array(payload))
        #expect(remainder.isEmpty)
    }

    @Test("empty input produces no output in both modes")
    func emptyInput() throws {
        let (framed, r1) = collect(Data(), ttyMode: false)
        let (raw, r2) = collect(Data(), ttyMode: true)
        #expect(framed.isEmpty)
        #expect(raw.isEmpty)
        #expect(r1.isEmpty)
        #expect(r2.isEmpty)
    }

    // MARK: - timestamps=true

    /// `2026-07-07T12:34:56.789Z ` — an RFC3339 UTC timestamp followed by a space,
    /// matching AppleContainerTimestampResolver.iso8601Timestamp's output shape.
    nonisolated(unsafe) private static let timestampPrefixPattern = try! Regex(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z "#)

    @Test("a complete line is stamped with a leading RFC3339 timestamp")
    func timestampsStampsACompleteLine() throws {
        let payload = Data("hello\n".utf8)
        let (bytes, remainder) = collect(payload, ttyMode: true, timestamps: true)

        let line = String(decoding: bytes, as: UTF8.self)
        #expect(line.hasSuffix("hello\n"))
        #expect(try Self.timestampPrefixPattern.firstMatch(in: line) != nil)
        #expect(remainder.isEmpty)
    }

    @Test("timestamps mode leaves a line with no trailing newline unflushed in the remainder")
    func timestampsDoesNotFlushAnIncompleteLine() throws {
        let payload = Data("partial line, no newline yet".utf8)
        let (bytes, remainder) = collect(payload, ttyMode: true, timestamps: true)

        #expect(bytes.isEmpty, "an incomplete line must not be stamped or emitted yet")
        #expect(remainder == payload)
    }

    @Test("timestamps mode stamps each complete line independently within one buffer")
    func timestampsStampsMultipleLinesIndependently() throws {
        let payload = Data("first\nsecond\nthird, incomplete".utf8)
        let (bytes, remainder) = collect(payload, ttyMode: true, timestamps: true)

        let output = String(decoding: bytes, as: UTF8.self)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 2)
        for line in lines {
            #expect(try Self.timestampPrefixPattern.firstMatch(in: String(line)) != nil)
        }
        #expect(output.contains("first\n"))
        #expect(output.contains("second\n"))
        #expect(remainder == Data("third, incomplete".utf8))
    }

    @Test("timestamps=false ignores embedded newlines and frames the whole buffer as-is")
    func noTimestampsFramesWholeBufferRegardlessOfNewlines() throws {
        let payload = Data("first\nsecond\n".utf8)
        let (bytes, remainder) = collect(payload, ttyMode: true, timestamps: false)

        #expect(bytes == Array(payload), "without timestamps, lines are never split or stamped")
        #expect(remainder.isEmpty)
    }

    @Test("flushFinalLogLine stamps and emits a trailing line with no newline")
    func flushFinalLogLineStampsTrailingLine() throws {
        var out = ByteBuffer()
        let trailing = Data("no trailing newline".utf8)
        ContainerLogsRoute.flushFinalLogLine(trailing, ttyMode: true, timestamps: true) { frame in
            out.writeImmutableBuffer(frame)
        }

        let output = String(buffer: out)
        #expect(output.hasSuffix("no trailing newline"))
        #expect(try Self.timestampPrefixPattern.firstMatch(in: output) != nil)
    }

    @Test("flushFinalLogLine does nothing for an empty buffer or when timestamps is false")
    func flushFinalLogLineNoOpWhenEmptyOrDisabled() throws {
        var out = ByteBuffer()
        let writeOutput: (ByteBuffer) -> Void = { frame in out.writeImmutableBuffer(frame) }

        ContainerLogsRoute.flushFinalLogLine(Data(), ttyMode: true, timestamps: true, writeOutput: writeOutput)
        ContainerLogsRoute.flushFinalLogLine(Data("leftover".utf8), ttyMode: true, timestamps: false, writeOutput: writeOutput)

        #expect(out.readableBytes == 0)
    }
}
