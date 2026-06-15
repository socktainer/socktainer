import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

// MARK: - Stop

@Suite("ContainerStopRoute — event label forwarding")
struct ContainerStopEventLabelTests {

    @Test("Stop event Actor.Attributes carries container labels, image, and name")
    func stopEventCarriesLabels() async throws {
        let id = "stop-ctr-hex"
        let nativeId = "stop-native"
        let snapshot = makeSnapshot(nativeId: nativeId, image: "redis:7", labels: ["svc": "cache"])
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
            try app.register(collection: ContainerStopRoute(client: EventMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/\(id)/stop") { res async in
                #expect(res.status == .noContent)
            }
        }

        captureTask.cancel()
        let event = await captureTask.value
        #expect(event?.Actor.Attributes["svc"] == "cache")
        #expect(event?.Actor.Attributes["image"] == "redis:7")
        #expect(event?.Actor.Attributes["name"] == nativeId)
    }
}

// MARK: - Restart

@Suite("ContainerRestartRoute — event label forwarding")
struct ContainerRestartEventLabelTests {

    @Test("Restart event Actor.Attributes carries container labels, image, and name")
    func restartEventCarriesLabels() async throws {
        let id = "restart-ctr-hex"
        let nativeId = "restart-native"
        let snapshot = makeSnapshot(nativeId: nativeId, image: "nginx:latest", labels: ["role": "proxy"])
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
            try app.register(collection: ContainerRestartRoute(client: EventMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/\(id)/restart") { res async in
                #expect(res.status == .noContent)
            }
        }

        captureTask.cancel()
        let event = await captureTask.value
        #expect(event?.Actor.Attributes["role"] == "proxy")
        #expect(event?.Actor.Attributes["image"] == "nginx:latest")
        #expect(event?.Actor.Attributes["name"] == nativeId)
    }
}

// MARK: - Delete (success path)

@Suite("ContainerDeleteRoute — event label forwarding")
struct ContainerDeleteEventLabelTests {

    @Test("Remove event carries labels from snapshot when container exists")
    func removeEventFromSnapshot() async throws {
        let id = "del-ctr-hex"
        let nativeId = "del-native"
        let snapshot = makeSnapshot(nativeId: nativeId, image: "postgres:17", labels: ["db": "main"])
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "remove" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerDeleteRoute(client: EventMock(snapshot: snapshot)))

            try await app.testing().test(.DELETE, "/v1.51/containers/\(id)") { res async in
                #expect(res.status == .ok)
            }
        }

        captureTask.cancel()
        let event = await captureTask.value
        #expect(event?.Actor.Attributes["db"] == "main")
        #expect(event?.Actor.Attributes["image"] == "postgres:17")
        #expect(event?.Actor.Attributes["name"] == nativeId)
    }

    @Test("Remove event uses ContainerInfoCache when container is already gone (docker run --rm)")
    func removeEventFromCacheWhenNotFound() async throws {
        let hexId = "rm-ctr-hex"
        let nativeId = "rm-native"

        // Seed the cache as if ContainerStartRoute had run earlier.
        await ContainerInfoCache.shared.set(
            hexId: hexId, nativeId: nativeId,
            image: "alpine:latest", labels: ["app": "ephemeral"]
        )

        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "remove" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerDeleteRoute(client: NotFoundMock()))

            // Returns 404 because the container is already gone, but the event must fire.
            try await app.testing().test(.DELETE, "/v1.51/containers/\(hexId)") { res async in
                #expect(res.status == .notFound)
            }
        }

        captureTask.cancel()
        let event = await captureTask.value
        #expect(event?.Actor.Attributes["app"] == "ephemeral")
        #expect(event?.Actor.Attributes["image"] == "alpine:latest")
        #expect(event?.Actor.Attributes["name"] == nativeId)
        // Cache must be cleared after the event.
        #expect(await ContainerInfoCache.shared.get(id: hexId) == nil)
    }
}

// MARK: - Shared helpers

private func makeSnapshot(nativeId: String, image: String, labels: [String: String]) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: image,
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:abc", size: 0
        )
    )
    var config = ContainerConfiguration(id: nativeId, image: img, process: proc)
    config.labels = labels
    return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
}

/// Mock returning a fixed snapshot and succeeding on all mutations.
private struct EventMock: ClientContainerProtocol {
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

/// Mock whose getContainer and delete both throw notFound — simulates an auto-removed container.
private struct NotFoundMock: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws { throw ClientContainerError.notFound(id: id) }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
