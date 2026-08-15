import Foundation
import Testing

@testable import GlassDock

@Suite("Multiplexed guest connection")
struct GuestConnectionTests {
    @Test("readability callbacks stop before a closed descriptor is reused")
    func readGateStopsAfterClose() throws {
        let pair = try SocketPair.make()
        defer { try? pair.peer.close() }

        let gate = GuestReadGate()
        gate.close(pair.client)

        #expect(gate.read(pair.client) == nil)
    }

    @Test("matches responses to request identifiers")
    func multiplexesResponses() async throws {
        let pair = try SocketPair.make()
        defer { try? pair.peer.close() }
        let connection = try await GuestConnection.connect { pair.client }

        let peer = pair.peer
        let responseComplete = AsyncStream<Void>.makeStream()
        Thread.detachNewThread {
            var codec = GuestFrameCodec()
            do {
                var responseCount = 0
                while responseCount < 2 {
                    let bytes = try Self.readAvailable(peer)
                    guard !bytes.isEmpty else { return }
                    for request in try codec.append(bytes) {
                        let response = GuestFrame(
                            id: request.id,
                            kind: .response,
                            method: request.method,
                            payload: request.payload,
                            stream: nil,
                            data: nil,
                            error: nil,
                            exitCode: 0
                        )
                        try peer.write(contentsOf: GuestFrameCodec.encode(response))
                        responseCount += 1
                    }
                }
            } catch {
                Issue.record(error)
            }
            responseComplete.continuation.yield()
            responseComplete.continuation.finish()
        }

        let first = try await connection.request(
            method: "first", payload: .object(["value": .string("one")])
        )
        let second = try await connection.request(
            method: "second", payload: .object(["value": .string("two")])
        )
        let responses = [first, second]
        for await _ in responseComplete.stream { break }
        #expect(responses[0].method == "first")
        #expect(responses[1].method == "second")
        await connection.close()
    }

    @Test("delivers guest stream frames before the matching end frame")
    func preservesStreamOrder() async throws {
        let pair = try SocketPair.make()
        defer { try? pair.peer.close() }
        let connection = try await GuestConnection.connect { pair.client }
        let streams = LockedFrames()

        let peer = pair.peer
        Thread.detachNewThread {
            do {
                var codec = GuestFrameCodec()
                var request: GuestFrame?
                while request == nil {
                    let bytes = try Self.readAvailable(peer)
                    guard !bytes.isEmpty else { return }
                    request = try codec.append(bytes).first
                }
                guard let request else { return }
                let stdout = GuestFrame(
                    id: request.id,
                    kind: .stream,
                    method: nil,
                    payload: nil,
                    stream: .stdout,
                    data: Data("out".utf8),
                    error: nil,
                    exitCode: nil
                )
                let stderr = GuestFrame(
                    id: request.id,
                    kind: .stream,
                    method: nil,
                    payload: nil,
                    stream: .stderr,
                    data: Data("err".utf8),
                    error: nil,
                    exitCode: nil
                )
                let exitCode: Int32 = 7
                let end = GuestFrame(
                    id: request.id,
                    kind: .end,
                    method: nil,
                    payload: nil,
                    stream: nil,
                    data: nil,
                    error: nil,
                    exitCode: exitCode
                )
                try peer.write(
                    contentsOf: GuestFrameCodec.encode(stdout)
                        + GuestFrameCodec.encode(stderr)
                        + GuestFrameCodec.encode(end)
                )
            } catch {
                Issue.record(error)
            }
        }

        let end = try await connection.request(
            method: "container.exec",
            payload: .object([:]),
            onStream: { streams.append($0) }
        )
        let received = streams.values

        #expect(received.map(\.stream) == [.stdout, .stderr])
        #expect(received.map(\.data) == [Data("out".utf8), Data("err".utf8)])
        #expect(end.kind == .end)
        #expect(end.exitCode == 7)
        await connection.close()
    }

    @Test("cancels a pending request without closing the connection")
    func cancelsPendingRequest() async throws {
        let pair = try SocketPair.make()
        defer { try? pair.peer.close() }
        let connection = try await GuestConnection.connect { pair.client }

        let request = Task {
            try await connection.request(method: "container.wait", payload: .object([:]))
        }
        _ = try Self.readAvailable(pair.peer)
        request.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await request.value
        }

        let peer = pair.peer
        Thread.detachNewThread {
            do {
                var codec = GuestFrameCodec()
                var next: GuestFrame?
                while next == nil {
                    next = try codec.append(Self.readAvailable(peer)).first { $0.kind == .request }
                }
                guard let next else { return }
                try peer.write(
                    contentsOf: GuestFrameCodec.encode(
                        GuestFrame(
                            id: next.id,
                            kind: .response,
                            method: next.method,
                            payload: .object(["ok": .bool(true)]),
                            stream: nil,
                            data: nil,
                            error: nil,
                            exitCode: nil
                        )
                    )
                )
            } catch {
                Issue.record(error)
            }
        }
        let response = try await connection.request(method: "ping", payload: .object([:]))
        #expect(response.payload == .object(["ok": .bool(true)]))
        await connection.close()
    }

    @Test("broadcasts guest events to every subscriber")
    func broadcastsEvents() async throws {
        let pair = try SocketPair.make()
        defer { try? pair.peer.close() }
        let connection = try await GuestConnection.connect { pair.client }
        let first = await connection.events()
        let second = await connection.events()
        let event = GuestFrame(
            id: 0,
            kind: .event,
            method: "bind.write.barrier",
            payload: .object([
                "barrierId": .string("1"), "paths": .array([.string("project/file")]),
            ]),
            stream: nil,
            data: nil,
            error: nil,
            exitCode: nil
        )

        try pair.peer.write(contentsOf: GuestFrameCodec.encode(event))
        let firstEvent = await first.first { _ in true }
        let secondEvent = await second.first { _ in true }

        #expect(firstEvent == event)
        #expect(secondEvent == event)
        await connection.close()
    }

    private static func readAvailable(_ handle: FileHandle) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

private final class LockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [GuestFrame] = []

    var values: [GuestFrame] {
        lock.withLock { frames }
    }

    func append(_ frame: GuestFrame) {
        lock.withLock { frames.append(frame) }
    }
}

private struct SocketPair {
    let client: FileHandle
    let peer: FileHandle

    static func make() throws -> SocketPair {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return SocketPair(
            client: FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
            peer: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        )
    }
}
