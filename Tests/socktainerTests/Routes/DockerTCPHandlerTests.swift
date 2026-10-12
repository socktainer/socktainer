import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import socktainer

/// Unit tests for DockerTCPHandler stdin coordination.
///
/// These tests exercise writeToStdin(), simulateInputClosed(), and
/// simulateChannelInactive() — internal helpers that call the same logic
/// as channelRead / userInboundEventTriggered — without requiring NIO
/// EmbeddedChannel (which has significant build overhead; see PR #231).
///
/// Async writes go through DockerTCPHandler.writeQueue (a serial
/// DispatchQueue). Tests that inspect pipe state after async writes call
/// drainForTesting() to synchronise, or use readDataToEndOfFile() which
/// naturally blocks until the write end is closed.
@Suite("DockerTCPHandler — stdin coordination")
struct DockerTCPHandlerTests {

    // MARK: - writeToStdin before setStdinWriter (pending buffer)

    @Test("data written before setStdinWriter is buffered and flushed on set")
    func pendingDataFlushedOnSetStdinWriter() throws {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()

        handler.writeToStdin(Data("hello".utf8))
        handler.setStdinWriter(pipe.fileHandleForWriting)
        handler.drainForTesting()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(data: data, encoding: .utf8) == "hello")
    }

    @Test("multiple buffered chunks flushed in order")
    func multipleChunksFlushedInOrder() throws {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()

        handler.writeToStdin(Data("foo".utf8))
        handler.writeToStdin(Data("bar".utf8))
        handler.writeToStdin(Data("baz".utf8))
        handler.setStdinWriter(pipe.fileHandleForWriting)
        handler.drainForTesting()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(data: data, encoding: .utf8) == "foobarbaz")
    }

    // MARK: - writeToStdin after setStdinWriter (direct write)

    @Test("data written after setStdinWriter flows through writeQueue to the pipe")
    func dataAfterSetWrittenDirectly() throws {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()

        handler.setStdinWriter(pipe.fileHandleForWriting)
        handler.writeToStdin(Data("direct".utf8))
        handler.drainForTesting()
        try pipe.fileHandleForWriting.close()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(data: data, encoding: .utf8) == "direct")
    }

    // MARK: - setStdinWriter contract

    @Test("setStdinWriter(nil) does not crash")
    func setStdinWriterNilIsSafe() {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        handler.setStdinWriter(nil)
    }

    @Test("second setStdinWriter call replaces the writer — writes go to new pipe only")
    func setStdinWriterCalledTwiceReplacesWriter() throws {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipeA = Pipe()
        let pipeB = Pipe()

        handler.setStdinWriter(pipeA.fileHandleForWriting)
        handler.setStdinWriter(pipeB.fileHandleForWriting)
        handler.writeToStdin(Data("second".utf8))
        handler.drainForTesting()
        try pipeB.fileHandleForWriting.close()
        try pipeA.fileHandleForWriting.close()

        let dataB = pipeB.fileHandleForReading.readDataToEndOfFile()
        #expect(String(data: dataB, encoding: .utf8) == "second")

        let dataA = pipeA.fileHandleForReading.readDataToEndOfFile()
        #expect(dataA.isEmpty)
    }

    // MARK: - inputClosed race condition

    @Test("inputClosed before setStdinWriter: buffered data flushed then write end closed")
    func inputClosedBeforeSetStdinWriterFlushesAndCloses() throws {
        // Without didReceiveInputClosed this test would hang because the
        // write end would never be closed and readDataToEndOfFile() blocks.
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()

        handler.writeToStdin(Data("piped".utf8))
        handler.simulateInputClosed()
        handler.setStdinWriter(pipe.fileHandleForWriting)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(data: data, encoding: .utf8) == "piped")
    }

    @Test("inputClosed before setStdinWriter with no pending data closes write end")
    func inputClosedBeforeSetStdinWriterNoDataClosesWriter() throws {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()

        handler.simulateInputClosed()
        handler.setStdinWriter(pipe.fileHandleForWriting)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(data.isEmpty)
    }

    // MARK: - inputClosed during flush (deferred close via writeQueue ordering)

    @Test("inputClosed during flush: all data flushed before write end closes")
    func inputClosedDuringFlushDataFlushedBeforeClose() async throws {
        // Fills the pipe buffer so setStdinWriter's flush blocks mid-write.
        // simulateInputClosed is injected from a concurrent thread while the
        // flush is stalled. The reader unblocks the flush. All data must arrive
        // before EOF — the writeQueue serialisation guarantees this.
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()

        let abovePipeBuffer = Data(repeating: 0x41, count: 65_537)
        let sentinel = Data([0xFF])
        handler.writeToStdin(abovePipeBuffer)
        handler.writeToStdin(sentinel)

        // Flush in background — will block when the pipe buffer fills
        let flushTask = Task.detached { handler.setStdinWriter(pipe.fileHandleForWriting) }
        // Reader runs concurrently, draining the pipe so flush can progress
        let readTask = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }

        // Give the flush time to block
        try await Task.sleep(nanoseconds: 10_000_000)

        // Inject close while flush is in progress
        handler.simulateInputClosed()

        await flushTask.value
        let received = await readTask.value

        #expect(received.count == abovePipeBuffer.count + sentinel.count)
        #expect(received.last == 0xFF)
    }

    // MARK: - channelInactive race

    @Test("setStdinWriter called after channelInactive immediately closes the writer")
    func setStdinWriterAfterChannelInactiveClosesWriter() throws {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()

        handler.simulateChannelInactive()
        handler.setStdinWriter(pipe.fileHandleForWriting)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(data.isEmpty)
    }

    // MARK: - pendingData threshold (backpressure, issue #453)

    @Test("data beyond 1 MiB before setStdinWriter is kept and flushed in order")
    func pendingDataBeyondThresholdIsNotDropped() async throws {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let pipe = Pipe()
        let chunkSize = 512 * 1024
        let chunks = [UInt8(0x41), 0x42, 0x43].map { Data(repeating: $0, count: chunkSize) }

        #expect(handler.writeToStdin(chunks[0]) == false)
        #expect(handler.writeToStdin(chunks[1]) == true)  // reaches 1 MiB — pause reads
        #expect(handler.writeToStdin(chunks[2]) == false)  // late read still buffered, no second pause
        #expect(handler.readPausedForTesting)
        #expect(handler.pendingDataSizeForTesting == 3 * chunkSize)

        let readTask = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        handler.setStdinWriter(pipe.fileHandleForWriting)
        #expect(handler.readPausedForTesting == false)
        handler.simulateInputClosed()

        let received = await readTask.value
        #expect(received == chunks.reduce(Data(), +))
    }

    @Test("on a real socket, reads pause at 1 MiB and resume on setStdinWriter with every byte delivered")
    func backpressureTogglesAutoReadOnRealChannel() async throws {
        // EmbeddedChannel always reports autoRead == true, so this uses a loopback socket.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let childPromise = group.next().makePromise(of: Channel.self)
        let server = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(handler).map { childPromise.succeed(channel) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let client = try await ClientBootstrap(group: group).connect(to: server.localAddress!).get()
        let child = try await childPromise.futureResult.get()

        let chunkSize = 1024 * 1024
        let chunks = [UInt8(0x41), 0x42, 0x43, 0x44].map { Data(repeating: $0, count: chunkSize) }
        for chunk in chunks { client.write(ByteBuffer(bytes: chunk), promise: nil) }
        client.flush()

        try #require(await waitUntil { try await child.getOption(ChannelOptions.autoRead).get() == false })
        // The rest is held back in socket buffers, not read into memory.
        #expect(handler.pendingDataSizeForTesting < 4 * chunkSize)

        let pipe = Pipe()
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        handler.setStdinWriter(pipe.fileHandleForWriting)
        try #require(await waitUntil { try await child.getOption(ChannelOptions.autoRead).get() })

        try await client.writeAndFlush(ByteBuffer(bytes: [0xFF])).get()
        try await client.close(mode: .output).get()
        let received = await reader.value
        #expect(received == chunks.reduce(Data(), +) + Data([0xFF]))

        try await client.close()
        try await server.close()
        try await group.shutdownGracefully()
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<500 {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
