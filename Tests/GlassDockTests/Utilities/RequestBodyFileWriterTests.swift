import Foundation
import Testing
import Vapor

@testable import GlassDock

@Suite("Request body file writer")
struct RequestBodyFileWriterTests {
    @Test("temporary request directories are private to the daemon user")
    func createsPrivateTemporaryDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let directory =
            try RequestBodyFileWriter
            .createSecureTemporaryDirectory(in: parent)
        let permissions =
            try FileManager.default.attributesOfItem(
                atPath: directory.path
            )[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o700)
    }

    @Test("streamed chunks are written in order without collection")
    func writesStreamedChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("archive.tar")
        let stream = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: "first-"))
            continuation.yield(ByteBuffer(string: "second"))
            continuation.finish()
        }

        let count = try await RequestBodyFileWriter.write(
            stream,
            to: destination,
            maxBytes: 64,
            kind: "test archive"
        )

        #expect(count == 12)
        #expect(try Data(contentsOf: destination) == Data("first-second".utf8))
        let permissions =
            try FileManager.default.attributesOfItem(
                atPath: destination.path
            )[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("the disk-backed writer accepts the exact bound and rejects the next byte")
    func enforcesLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("archive.tar")
        let stream = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: "1234"))
            continuation.yield(ByteBuffer(string: "5"))
            continuation.finish()
        }

        do {
            _ = try await RequestBodyFileWriter.write(
                stream,
                to: destination,
                maxBytes: 4,
                kind: "test archive"
            )
            Issue.record("expected the stream size limit to fail")
        } catch let abort as Abort {
            #expect(abort.status == .payloadTooLarge)
            #expect(abort.reason == "test archive exceeds the 4-byte limit")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        let exactStream = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: "1234"))
            continuation.finish()
        }
        let exactCount = try await RequestBodyFileWriter.write(
            exactStream,
            to: destination,
            maxBytes: 4,
            kind: "test archive"
        )
        #expect(exactCount == 4)
        #expect(try Data(contentsOf: destination) == Data("1234".utf8))
    }

    @Test("source errors remove the partially written archive")
    func sourceErrorCleansUp() async throws {
        enum SourceFailure: Error { case failed }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("archive.tar")
        let stream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            continuation.yield(ByteBuffer(string: "partial"))
            continuation.finish(throwing: SourceFailure.failed)
        }

        do {
            _ = try await RequestBodyFileWriter.write(
                stream,
                to: destination,
                maxBytes: 64,
                kind: "test archive"
            )
            Issue.record("expected the source error to propagate")
        } catch SourceFailure.failed {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("cancellation removes the partially written archive")
    func cancellationCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("archive.tar")
        var continuation: AsyncStream<ByteBuffer>.Continuation?
        let stream = AsyncStream<ByteBuffer> {
            continuation = $0
        }
        continuation?.yield(ByteBuffer(string: "partial"))

        let writeTask = Task {
            try await RequestBodyFileWriter.write(
                stream,
                to: destination,
                maxBytes: 64,
                kind: "test archive"
            )
        }
        for _ in 0..<100 {
            if (try? Data(contentsOf: destination).count) == 7 { break }
            await Task.yield()
        }
        writeTask.cancel()
        continuation?.finish()

        do {
            _ = try await writeTask.value
            Issue.record("expected cancellation to propagate")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
