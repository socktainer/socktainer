import ContainerAPIClient
import Foundation
import Logging

/// Holds the stdio of stopped containers that a client attached to before starting them.
///
/// Docker holds an attach to a container that is not running open until the container starts.
/// `docker run` and `docker start -a` attach first and then send `POST /start`, and attached
/// `docker compose up` attaches to every service and then starts each one, in dependency order,
/// with `POST /start`. Apple Container takes a container's stdio when it boots, so the attach
/// route cannot connect pipes to a container that `/start` boots later. Instead it parks its
/// pipes here; `/start` boots the container with them and hands the started process back to
/// the attach stream that is waiting for it.
///
/// The attach route must not boot the container itself. A booted container reports as running,
/// and Compose skips `POST /start` for a running container, so every service would start at
/// attach time, in no particular order, without `/start`'s DNS registration and healthcheck
/// (socktainer/socktainer#472).
actor PendingAttachStart {
    static let shared = PendingAttachStart()

    enum WaitError: Error {
        /// The container was not started with the parked pipes: `/start` failed, or the client
        /// disconnected first.
        case notStarted
    }

    private struct Entry {
        let token: UUID
        let pipes: StdioPipes
        var claimed = false
        var result: Result<ClientProcess, Error>?
        var waiter: CheckedContinuation<ClientProcess, Error>?
    }

    private var entries: [String: Entry] = [:]
    private let log = Logger(label: "socktainer.attach.pending")

    /// Parks `pipes` until the container is started. Returns nil when another attach is already
    /// waiting on the same container; Apple Container gives a container one set of stdio.
    func park(containerId: String, pipes: StdioPipes) -> UUID? {
        guard entries[containerId] == nil else { return nil }
        let token = UUID()
        entries[containerId] = Entry(token: token, pipes: pipes)
        log.info("[attach] parked stdio for \(containerId) until it is started")
        return token
    }

    /// Called by the start path before it boots the container. Returns the parked pipes, which
    /// the caller then owns, or nil when no attach is waiting.
    func claim(containerId: String) -> StdioPipes? {
        guard var entry = entries[containerId], !entry.claimed else { return nil }
        entry.claimed = true
        entries[containerId] = entry
        return entry.pipes
    }

    /// Called by the start path once it has started the container with the claimed pipes, or
    /// failed to. Hands the result to the waiting attach.
    func finish(containerId: String, result: Result<ClientProcess, Error>) {
        guard var entry = entries[containerId], entry.claimed else { return }
        if let waiter = entry.waiter {
            entries.removeValue(forKey: containerId)
            waiter.resume(with: result)
        } else {
            entry.result = result
            entries[containerId] = entry
        }
    }

    /// Waits for the container to be started with the pipes parked under `token`.
    func waitForStart(containerId: String, token: UUID) async throws -> ClientProcess {
        guard var entry = entries[containerId], entry.token == token else { throw WaitError.notStarted }
        if let result = entry.result {
            entries.removeValue(forKey: containerId)
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            entry.waiter = continuation
            entries[containerId] = entry
        }
    }

    /// Withdraws pipes parked under `token` because their client went away. True when they were
    /// withdrawn before `/start` claimed them, in which case the caller still owns them and must
    /// close them; false when `/start` already took them over, or they are gone.
    func cancel(containerId: String, token: UUID) -> Bool {
        guard let entry = entries[containerId], entry.token == token, !entry.claimed else { return false }
        entries.removeValue(forKey: containerId)
        entry.waiter?.resume(throwing: WaitError.notStarted)
        log.info("[attach] client left before \(containerId) was started; released its stdio")
        return true
    }

    /// Waits for `/start` to start the container with `pipes`, or for the client to go away
    /// first, whichever happens first. `clientGone` returns once the client has disconnected.
    /// Returns nil when the container was not started; the pipes are closed by then.
    static func awaitStart(
        containerId: String,
        token: UUID,
        pipes: StdioPipes,
        clientGone: @escaping @Sendable () async -> Void
    ) async -> ClientProcess? {
        let watcher = Task {
            await clientGone()
            if await shared.cancel(containerId: containerId, token: token) {
                pipes.closeAll()
            }
        }
        defer { watcher.cancel() }
        return try? await shared.waitForStart(containerId: containerId, token: token)
    }
}
