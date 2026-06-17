import Foundation
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

    // MARK: - pendingData cap

    @Test("pendingData cap: data beyond 1 MiB is discarded, buffer stays at cap")
    func pendingDataCapDiscardsOverflow() {
        let handler = DockerTCPHandler(execId: "test", ttyEnabled: false)
        let cap = 1 * 1024 * 1024

        let chunk = Data(repeating: 0x41, count: 512 * 1024)
        handler.writeToStdin(chunk)
        handler.writeToStdin(chunk)  // exactly at cap
        handler.writeToStdin(chunk)  // over cap — discarded

        #expect(handler.pendingDataSizeForTesting == cap)
    }
}
