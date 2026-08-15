import Darwin
import Foundation

enum GuestConnectionError: Error, Equatable {
    case closed
    case invalidResponseKind(GuestFrameKind)
}

actor GuestConnection {
    typealias Connector = @Sendable () async throws -> FileHandle

    private let handle: FileHandle
    private let descriptor: Int32
    private let writer: GuestSocketWriter
    private let readGate = GuestReadGate()
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

    private init(handle: FileHandle) throws {
        self.handle = handle
        self.descriptor = handle.fileDescriptor
        self.writer = try GuestSocketWriter(descriptor: descriptor)
    }

    static func connect(using connector: Connector) async throws -> GuestConnection {
        let connection = try GuestConnection(handle: try await connector())
        await connection.startReader()
        return connection
    }

    deinit {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        writer.close()
        readGate.close(handle)
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
        try Task.checkCancellation()
        let id = allocateRequestID()
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(continuation: continuation, onStream: onStream)
                Task {
                    do {
                        try await writer.write(encoded)
                    } catch {
                        failRequest(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    func events() -> AsyncStream<GuestFrame> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4_096)) { continuation in
            eventContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(token) }
            }
        }
    }

    func close() {
        finish(GuestConnectionError.closed)
    }

    func isTerminal() -> Bool {
        terminalError != nil
    }

    private func startReader() {
        guard !reading else { return }
        reading = true
        let reads = AsyncStream<Data>.makeStream()
        readContinuation = reads.continuation
        let readGate = readGate
        handle.readabilityHandler = { readable in
            guard let data = readGate.read(readable) else { return }
            reads.continuation.yield(data)
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
        readGate.close(handle)
        readContinuation?.finish()
        readContinuation = nil
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        writer.close()
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

    private func allocateRequestID() -> UInt64 {
        repeat {
            let candidate = nextID
            nextID &+= 1
            if candidate != 0, pending[candidate] == nil {
                return candidate
            }
        } while true
    }

    private func cancelRequest(id: UInt64) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CancellationError())
        let cancel = GuestFrame(
            id: id, kind: .cancel, method: nil, payload: nil, stream: nil,
            data: nil, error: nil, exitCode: nil
        )
        Task { try? await writer.write(GuestFrameCodec.encode(cancel)) }
    }

    private func failRequest(id: UInt64, error: Error) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }
}

final class GuestReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    func read(_ handle: FileHandle) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        return handle.availableData
    }

    func close(_ handle: FileHandle) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        handle.readabilityHandler = nil
        try? handle.close()
        lock.unlock()
    }
}

private final class GuestSocketWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "glassdock.guest-connection.writer")
    private var closed = false

    init(descriptor: Int32) throws {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        self.descriptor = duplicate
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            Darwin.close(descriptor)
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !self.closed else { throw GuestConnectionError.closed }
                    try data.withUnsafeBytes { buffer in
                        guard let baseAddress = buffer.baseAddress else { return }
                        var written = 0
                        while written < buffer.count {
                            let count = Darwin.send(
                                self.descriptor,
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
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
