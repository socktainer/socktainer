import Foundation
import Vapor

/// JSON frames for Docker's progress-stream protocol (push/pull/load).
/// Failures must travel as a final error frame on a cleanly-ended body:
/// aborting the connection makes the docker CLI report "unexpected EOF".
enum DockerProgressFrame {
    private struct StatusFrame: Encodable {
        let status: String
    }

    private struct ErrorFrame: Encodable {
        struct Detail: Encodable {
            let message: String
        }
        let errorDetail: Detail
        let error: String
    }

    private struct StreamFrame: Encodable {
        let stream: String
    }

    private struct ProgressBarFrame: Encodable {
        struct Detail: Encodable {
            let current: Int64
            let total: Int64
        }
        let status: String
        let id: String
        let progressDetail: Detail
    }

    static func status(_ message: String) -> String {
        encode(StatusFrame(status: message))
    }

    static func stream(_ message: String) -> String {
        encode(StreamFrame(stream: message))
    }

    static func progress(status: String, id: String, current: Int64, total: Int64) -> String {
        encode(ProgressBarFrame(status: status, id: id, progressDetail: .init(current: current, total: total)))
    }

    static func error(_ message: String) -> String {
        encode(ErrorFrame(errorDetail: .init(message: message), error: message))
    }

    private static func encode(_ frame: some Encodable) -> String {
        guard let data = try? JSONEncoder().encode(frame), let json = String(data: data, encoding: .utf8) else {
            return #"{"error": "internal error"}"# + "\n"
        }
        return json + "\n"
    }

    static func write(
        _ frame: String,
        to writer: any BodyStreamWriter
    ) async throws {
        try await writer.write(.buffer(ByteBuffer(string: frame))).get()
    }

    static func write(
        _ frame: String,
        to writer: any AsyncBodyStreamWriter
    ) async throws {
        try await writer.writeBuffer(ByteBuffer(string: frame))
    }

    /// Streams progress messages as status frames, converts a thrown error
    /// into a final error frame, and always ends the body cleanly.
    static func pipe(
        _ progress: AsyncThrowingStream<String, Error>,
        to writer: any BodyStreamWriter,
        onSuccess: (() async -> Void)? = nil
    ) async {
        var iterator = progress.makeAsyncIterator()
        while true {
            let message: String?
            do {
                message = try await iterator.next()
            } catch {
                do {
                    try await write(
                        Self.error(String(describing: error)),
                        to: writer
                    )
                    try await writer.write(.end).get()
                } catch {
                    await cancelProducer(&iterator)
                }
                return
            }
            guard let message else {
                await onSuccess?()
                _ = try? await writer.write(.end).get()
                return
            }
            do {
                try await write(status(message), to: writer)
            } catch {
                await cancelProducer(&iterator)
                return
            }
        }
    }

    /// Pull variant: byte counts become a single aggregate progress bar
    /// keyed on `id` (apple/container reports no per-layer attribution).
    static func pipe(
        _ progress: AsyncThrowingStream<PullProgress, Error>,
        id: String,
        to writer: any BodyStreamWriter,
        onSuccess: (() async -> Void)? = nil
    ) async {
        var iterator = progress.makeAsyncIterator()
        while true {
            let update: PullProgress?
            do {
                update = try await iterator.next()
            } catch {
                do {
                    try await write(
                        Self.error(String(describing: error)),
                        to: writer
                    )
                    try await writer.write(.end).get()
                } catch {
                    await cancelProducer(&iterator)
                }
                return
            }
            guard let update else {
                await onSuccess?()
                _ = try? await writer.write(.end).get()
                return
            }

            let frame: String
            switch update {
            case .message(let message):
                frame = status(message)
            case .downloading(let current, let total):
                frame = Self.progress(
                    status: "Downloading",
                    id: id,
                    current: current,
                    total: total
                )
            case .extracting(let current, let total):
                frame = Self.progress(
                    status: "Extracting",
                    id: id,
                    current: current,
                    total: total
                )
            }
            do {
                try await write(frame, to: writer)
            } catch {
                await cancelProducer(&iterator)
                return
            }
        }
    }

    /// Managed-response variant. It never writes `.end` (Vapor owns that),
    /// propagates channel failure to the disconnect-coupling task group, and
    /// explicitly terminates the service stream when its consumer is cancelled.
    static func pipe(
        _ progress: AsyncThrowingStream<String, Error>,
        to writer: any AsyncBodyStreamWriter,
        onSuccess: (@Sendable () async -> Void)? = nil
    ) async throws {
        var iterator = progress.makeAsyncIterator()
        while true {
            let message: String?
            do {
                message = try await iterator.next()
                try Task.checkCancellation()
            } catch is CancellationError {
                await cancelProducer(&iterator)
                throw CancellationError()
            } catch {
                try await write(
                    Self.error(String(describing: error)),
                    to: writer
                )
                return
            }
            guard let message else {
                await onSuccess?()
                try Task.checkCancellation()
                return
            }
            do {
                try await write(status(message), to: writer)
            } catch {
                await cancelProducer(&iterator)
                throw error
            }
        }
    }

    /// Pull variant for a managed response body. Byte counts become one
    /// aggregate progress bar, matching the legacy writer overload above.
    static func pipe(
        _ progress: AsyncThrowingStream<PullProgress, Error>,
        id: String,
        to writer: any AsyncBodyStreamWriter,
        onSuccess: (@Sendable () async -> Void)? = nil
    ) async throws {
        var iterator = progress.makeAsyncIterator()
        while true {
            let update: PullProgress?
            do {
                update = try await iterator.next()
                try Task.checkCancellation()
            } catch is CancellationError {
                await cancelProducer(&iterator)
                throw CancellationError()
            } catch {
                try await write(
                    Self.error(String(describing: error)),
                    to: writer
                )
                return
            }
            guard let update else {
                await onSuccess?()
                try Task.checkCancellation()
                return
            }

            let frame: String
            switch update {
            case .message(let message):
                frame = status(message)
            case .downloading(let current, let total):
                frame = Self.progress(
                    status: "Downloading",
                    id: id,
                    current: current,
                    total: total
                )
            case .extracting(let current, let total):
                frame = Self.progress(
                    status: "Extracting",
                    id: id,
                    current: current,
                    total: total
                )
            }
            do {
                try await write(frame, to: writer)
            } catch {
                await cancelProducer(&iterator)
                throw error
            }
        }
    }

    /// AsyncStream notifies its producer when an awaiting consumer task is
    /// cancelled. On an HTTP write failure, explicitly cancel this pipe task and
    /// perform one terminal `next()` so the service's `onTermination` callback
    /// promptly cancels pull/push mutation work.
    private static func cancelProducer<Element>(
        _ iterator: inout AsyncThrowingStream<Element, Error>.Iterator
    ) async {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        _ = try? await iterator.next()
    }
}
