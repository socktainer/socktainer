import Darwin
import Foundation

enum GuestConnectionError: Error, Equatable {
    case closed
    case invalidResponseKind(GuestFrameKind)
}

actor GuestConnection {
    typealias Connector = @Sendable () async throws -> FileHandle

    private let handle: FileHandle
    private var nextID: UInt64 = 1
    private struct PendingRequest {
        let continuation: CheckedContinuation<GuestFrame, Error>
        let onStream: @Sendable (GuestFrame) -> Void
    }

    private var pending: [UInt64: PendingRequest] = [:]
    private var eventContinuations: [UUID: AsyncStream<GuestFrame>.Continuation] = [:]
    private var codec = GuestFrameCodec()
    private var readContinuation: AsyncStream<Data>.Continuation?
    private var reading = false
    private var terminalError: Error?

    private init(handle: FileHandle) {
        self.handle = handle
    }

    static func connect(using connector: Connector) async throws -> GuestConnection {
        let connection = GuestConnection(handle: try await connector())
        await connection.startReader()
        return connection
    }

    deinit {
        try? handle.close()
    }

    func request(method: String, payload: JSONValue? = nil) async throws -> GuestFrame {
        try await request(method: method, payload: payload, onStream: { _ in })
    }

    func request(
        method: String,
        payload: JSONValue? = nil,
        onStream: @escaping @Sendable (GuestFrame) -> Void
    ) async throws -> GuestFrame {
        if let terminalError { throw terminalError }
        let id = nextID
        nextID &+= 1
        let frame = GuestFrame(
            id: id,
            kind: .request,
            method: method,
            payload: payload,
            stream: nil,
            data: nil,
            error: nil,
            exitCode: nil
        )
        let encoded = try GuestFrameCodec.encode(frame)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(continuation: continuation, onStream: onStream)
            do {
                try Self.writeAll(encoded, to: handle.fileDescriptor)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func events() -> AsyncStream<GuestFrame> {
        let token = UUID()
        return AsyncStream { continuation in
            eventContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(token) }
            }
        }
    }

    func close() {
        finish(GuestConnectionError.closed)
    }

    private func startReader() {
        guard !reading else { return }
        reading = true
        let reads = AsyncStream<Data>.makeStream()
        readContinuation = reads.continuation
        handle.readabilityHandler = { readable in
            reads.continuation.yield(readable.availableData)
        }
        Task.detached { [weak self] in
            for await data in reads.stream {
                guard await self?.ingest(data) == true else { return }
            }
        }
    }

    private func ingest(_ data: Data) -> Bool {
        do {
            guard !data.isEmpty else {
                try codec.finish()
                finish(GuestConnectionError.closed)
                return false
            }
            for frame in try codec.append(data) {
                receive(frame)
            }
            return true
        } catch {
            finish(error)
            return false
        }
    }

    private nonisolated static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written,
                    MSG_NOSIGNAL
                )
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func receive(_ frame: GuestFrame) {
        if frame.id == 0 || frame.kind == .event {
            for continuation in eventContinuations.values {
                continuation.yield(frame)
            }
            return
        }
        guard frame.kind == .response || frame.kind == .end else {
            if frame.kind == .stream {
                pending[frame.id]?.onStream(frame)
                return
            }
            pending.removeValue(forKey: frame.id)?.continuation.resume(
                throwing: GuestConnectionError.invalidResponseKind(frame.kind)
            )
            return
        }
        guard let request = pending.removeValue(forKey: frame.id) else { return }
        if let error = frame.error {
            request.continuation.resume(throwing: error)
        } else {
            request.continuation.resume(returning: frame)
        }
    }

    private func finish(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        reading = false
        handle.readabilityHandler = nil
        readContinuation?.finish()
        readContinuation = nil
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
        try? handle.close()
        let continuations = pending.values
        pending.removeAll()
        for request in continuations {
            request.continuation.resume(throwing: error)
        }
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    private func removeEventContinuation(_ token: UUID) {
        eventContinuations.removeValue(forKey: token)
    }
}
