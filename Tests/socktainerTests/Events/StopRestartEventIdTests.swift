import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// stop/restart events must carry the canonical 64-char Docker id in
/// Actor.ID, like start/kill/die do — not the raw request reference
/// (container name or short id) the client happened to use. Clients such
/// as testcontainers correlate lifecycle events by that id.
@Suite("Stop/Restart events — canonical container id")
struct StopRestartEventIdTests {

    @Test("stop event carries the 64-char hex id, not the request reference")
    func stopEventUsesHexId() async throws {
        let snapshot = Self.snapshot(nativeId: "sockt-evtid-native")
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "stop" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerStopRoute(client: FixedSnapshotMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/sockt-evtid-native/stop") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await Self.withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["name"] == "sockt-evtid-native")
    }

    @Test("restart event carries the 64-char hex id, not the request reference")
    func restartEventUsesHexId() async throws {
        let snapshot = Self.snapshot(nativeId: "sockt-evtid-native")
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "restart" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerRestartRoute(client: FixedSnapshotMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/sockt-evtid-native/restart") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await Self.withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["name"] == "sockt-evtid-native")
    }

    // MARK: - Helpers

    private static func snapshot(nativeId: String) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc", size: 0
            )
        )
        let config = ContainerConfiguration(id: nativeId, image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }

    private static func withTimeout(_ task: Task<DockerEvent?, Never>, seconds: UInt64 = 5) async -> DockerEvent? {
        let timeoutTask = Task<DockerEvent?, Never> {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            task.cancel()
            return nil
        }
        let value = await task.value
        timeoutTask.cancel()
        return value
    }
}

// MARK: - Mocks

/// Mock whose getContainer resolves any reference to a fixed snapshot.
private struct FixedSnapshotMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
