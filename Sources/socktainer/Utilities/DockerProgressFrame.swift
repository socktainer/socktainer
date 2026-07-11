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

    static func write(_ frame: String, to writer: any BodyStreamWriter) {
        _ = writer.write(.buffer(ByteBuffer(string: frame)))
    }

    /// Streams progress messages as status frames, converts a thrown error
    /// into a final error frame, and always ends the body cleanly.
    static func pipe(
        _ progress: AsyncThrowingStream<String, Error>,
        to writer: any BodyStreamWriter,
        onSuccess: (() async -> Void)? = nil
    ) async {
        do {
            for try await message in progress {
                write(status(message), to: writer)
            }
            await onSuccess?()
        } catch {
            write(Self.error(String(describing: error)), to: writer)
        }
        _ = writer.write(.end)
    }

    /// Pull variant: byte counts become a single aggregate progress bar
    /// keyed on `id` (apple/container reports no per-layer attribution).
    static func pipe(
        _ progress: AsyncThrowingStream<PullProgress, Error>,
        id: String,
        to writer: any BodyStreamWriter,
        onSuccess: (() async -> Void)? = nil
    ) async {
        do {
            for try await update in progress {
                switch update {
                case .message(let message):
                    write(status(message), to: writer)
                case .downloading(let current, let total):
                    write(Self.progress(status: "Downloading", id: id, current: current, total: total), to: writer)
                case .extracting(let current, let total):
                    write(Self.progress(status: "Extracting", id: id, current: current, total: total), to: writer)
                }
            }
            await onSuccess?()
        } catch {
            write(Self.error(String(describing: error)), to: writer)
        }
        _ = writer.write(.end)
    }
}
