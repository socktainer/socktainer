import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// POST /containers/{id}/stop must follow the Docker Engine API contract for an
/// already-stopped container: moby's `containerStop` returns 304 Not Modified
/// when `!ctr.IsRunning()` and emits no stop/die event (the swagger documents
/// "304 container already stopped"). The previous implementation always called
/// `client.stop()` and broadcast a stop event regardless of state.
@Suite("ContainerStopRoute — already-stopped is 304")
struct ContainerStopAlreadyStoppedTests {

    @Test("Stopping an already-stopped container returns 304 and performs no stop")
    func stoppedReturnsNotModified() async throws {
        let log = CallLog()
        let mock = RecordingStopMock(snapshot: Self.snapshot(id: "idle-ctr", status: .stopped), log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStopRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/idle-ctr/stop") { res async in
                #expect(res.status == .notModified)
            }
        }

        let calls = await log.calls
        #expect(calls.isEmpty, "An already-stopped container must not be stopped again")
    }

    @Test("Stopping a running container returns 204 and stops it")
    func runningStops() async throws {
        let log = CallLog()
        let mock = RecordingStopMock(snapshot: Self.snapshot(id: "live-ctr", status: .running), log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStopRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/live-ctr/stop") { res async in
                #expect(res.status == .noContent)
            }
        }

        let calls = await log.calls
        #expect(calls == ["stop"], "A running container is stopped")
    }

    private static func snapshot(id: String, status: RuntimeStatus) -> ContainerSnapshot {
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
        let config = ContainerConfiguration(id: id, image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: status, networks: [])
    }
}

// MARK: - Mocks

private actor CallLog {
    var calls: [String] = []
    func add(_ call: String) { calls.append(call) }
}

private struct RecordingStopMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    let log: CallLog
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws { await log.add("stop") }
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
