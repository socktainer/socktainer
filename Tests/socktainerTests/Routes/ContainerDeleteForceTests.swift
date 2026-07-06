import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// DELETE /containers/{id} must follow the Docker Engine API force contract:
/// removing a running container without `force=true` is a 409 Conflict, and
/// only `force=true` stops the container before deleting it.
@Suite("ContainerDeleteRoute — force query parameter")
struct ContainerDeleteForceTests {

    @Test(
        "Deleting a live container without force returns 409 and performs no action",
        arguments: [RuntimeStatus.running, RuntimeStatus.stopping])
    func liveWithoutForceConflicts(status: RuntimeStatus) async throws {
        let log = CallLog()
        let mock = RecordingDeleteMock(snapshot: Self.snapshot(id: "live-ctr", status: status), log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/containers/live-ctr") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("stop the container before removing or force remove"))
            }
        }

        let calls = await log.calls
        #expect(!calls.contains("stop"), "A rejected delete must not stop the container")
        #expect(!calls.contains("delete"), "A rejected delete must not remove the container")
    }

    @Test(
        "Deleting a running container with force set stops then deletes it",
        arguments: ["force=1", "force=true"])
    func runningWithForceStopsAndDeletes(forceParam: String) async throws {
        let log = CallLog()
        let mock = RecordingDeleteMock(snapshot: Self.snapshot(id: "running-ctr", status: .running), log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/containers/running-ctr?\(forceParam)") { res async in
                #expect(res.status == .noContent)
            }
        }

        let calls = await log.calls
        #expect(calls == ["stop", "delete"], "force must stop the running container, then delete it")
    }

    @Test("Deleting a stopped container without force succeeds")
    func stoppedWithoutForceDeletes() async throws {
        let log = CallLog()
        let mock = RecordingDeleteMock(snapshot: Self.snapshot(id: "stopped-ctr", status: .stopped), log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/containers/stopped-ctr") { res async in
                #expect(res.status == .noContent)
            }
        }

        let calls = await log.calls
        #expect(calls == ["delete"], "A stopped container is deleted directly, without a stop call")
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

/// Mock that returns a fixed snapshot and records stop/delete calls in order.
private struct RecordingDeleteMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    let log: CallLog
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws { await log.add("stop") }
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws { await log.add("delete") }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
