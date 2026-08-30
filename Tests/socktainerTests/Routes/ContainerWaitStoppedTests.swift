import ContainerAPIClient
import ContainerResource
import Foundation
import Testing

@testable import socktainer

/// `docker compose up` issues `POST /wait` before `POST /start`, exactly as the Docker CLI does.
/// A container that exits immediately used to leave Compose blocked for the full 30s store poll,
/// because the native wait throws once the runtime client is gone. These tests pin both halves of
/// the contract: a finished container resolves fast, a not-yet-started one keeps waiting.
@Suite("ContainerWaitRoute.resolveNotRunning")
struct ContainerWaitStoppedTests {
    /// Reports `running` for the first `runningPolls` state queries, then `stopped`.
    private actor LifecycleClient: ClientContainerProtocol {
        private let running: ContainerSnapshot
        private let stopped: ContainerSnapshot
        private let runningPolls: Int
        private var polls = 0

        init(running: ContainerSnapshot, stopped: ContainerSnapshot, runningPolls: Int) {
            self.running = running
            self.stopped = stopped
            self.runningPolls = runningPolls
        }

        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [stopped] }

        func getContainer(id: String) async throws -> ContainerSnapshot? {
            polls += 1
            return polls <= runningPolls ? running : stopped
        }

        nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}

        /// Mirrors the real failure: the runtime client is gone, so the native wait throws.
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            throw ClientContainerError.notRunning(id: id)
        }

        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    private func snapshot(id: String, status: RuntimeStatus) throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: id,
            networks: [(network: "default", ip: "192.168.64.5")],
            labels: [:],
            status: status
        )
    }

    @Test("a container observed running then stopped resolves without waiting out the store poll")
    func exitedContainerResolvesQuickly() async throws {
        let identifier = "wait-exited"
        await ContainerExitCodeStore.shared.remove(id: identifier)

        let client = LifecycleClient(
            running: try snapshot(id: identifier, status: .running),
            stopped: try snapshot(id: identifier, status: .stopped),
            runningPolls: 1
        )

        let started = Date()
        let result = await ContainerWaitRoute.resolveNotRunning(
            containerId: identifier,
            client: client,
            storeTimeoutNs: 30_000_000_000
        )

        #expect(result.StatusCode == 0)
        #expect(Date().timeIntervalSince(started) < 5, "must not wait out the 30s store poll")
    }

    @Test("a recorded exit code is reported instead of a clean exit")
    func recordedExitCodeIsReported() async throws {
        let identifier = "wait-exit-3"
        await ContainerExitCodeStore.shared.set(id: identifier, code: 3)
        defer { Task { await ContainerExitCodeStore.shared.remove(id: identifier) } }

        let client = LifecycleClient(
            running: try snapshot(id: identifier, status: .running),
            stopped: try snapshot(id: identifier, status: .stopped),
            runningPolls: 1
        )

        let result = await ContainerWaitRoute.resolveNotRunning(
            containerId: identifier,
            client: client,
            storeTimeoutNs: 30_000_000_000
        )

        #expect(result.StatusCode == 3)
    }

    /// The dangerous regression: Compose waits before starting, so "not running yet" must never
    /// be reported as a finished container.
    @Test("a created container that never ran keeps waiting")
    func createdContainerDoesNotResolveEarly() async throws {
        let identifier = "wait-created"
        await ContainerExitCodeStore.shared.remove(id: identifier)

        let stopped = try snapshot(id: identifier, status: .stopped)
        let client = LifecycleClient(running: stopped, stopped: stopped, runningPolls: 0)

        let started = Date()
        _ = await ContainerWaitRoute.resolveNotRunning(
            containerId: identifier,
            client: client,
            storeTimeoutNs: 1_000_000_000
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed >= 0.9, "resolved after \(elapsed)s; a never-started container must keep waiting")
    }

    @Test("a die event resolves the wait with its exit code")
    func dieEventResolvesWait() async throws {
        let identifier = "wait-die-event"
        await ContainerExitCodeStore.shared.remove(id: identifier)

        let stopped = try snapshot(id: identifier, status: .stopped)
        let client = LifecycleClient(running: stopped, stopped: stopped, runningPolls: 0)

        let (stream, continuation) = AsyncStream.makeStream(of: DockerEvent.self)
        continuation.yield(
            DockerEvent.simpleEvent(
                id: identifier,
                type: "container",
                status: "die",
                extraAttributes: ["exitCode": "7"]
            )
        )

        let result = await ContainerWaitRoute.resolveNotRunning(
            containerId: identifier,
            client: client,
            events: stream,
            storeTimeoutNs: 30_000_000_000
        )

        #expect(result.StatusCode == 7)
        continuation.finish()
    }
}
