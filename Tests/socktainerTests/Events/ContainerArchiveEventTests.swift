import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// moby emits "archive-path" on a successful GET /containers/{id}/archive and
/// "extract-to-dir" on a successful PUT; HEAD emits nothing (daemon/archive_unix.go).
@Suite("Archive events")
struct ContainerArchiveEventTests {

    @Test("GET /archive broadcasts 'archive-path' on success")
    func getEmitsArchivePath() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: ["app": "web"], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "archive-path" { return event }
            return nil
        }

        try await withArchiveApp(snapshot: snapshot, archive: FakeArchiveClient(), broadcaster: broadcaster) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/archive?path=/etc/hosts") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "container")
        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["name"] == "web")
        #expect(event?.Actor.Attributes["app"] == "web")
    }

    @Test("a failed GET /archive broadcasts nothing")
    func failedGetStaysSilent() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "archive-path" { return event }
            return nil
        }

        try await withArchiveApp(snapshot: snapshot, archive: FakeArchiveClient(getResult: .failure(.pathNotFound(path: "/missing"))), broadcaster: broadcaster) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/archive?path=/missing") { res async in
                #expect(res.status == .notFound)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event == nil)
    }

    @Test("PUT /archive broadcasts 'extract-to-dir' on success")
    func putEmitsExtractToDir() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "extract-to-dir" { return event }
            return nil
        }

        try await withArchiveApp(snapshot: snapshot, archive: FakeArchiveClient(), broadcaster: broadcaster) { app in
            try await app.testing().test(
                .PUT, "/v1.51/containers/web/archive?path=/tmp",
                body: ByteBuffer(data: Data("fake-tar-bytes".utf8))
            ) { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "container")
        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
    }

    @Test("HEAD /archive broadcasts nothing, like moby")
    func headStaysSilent() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Type == "container" { return event }
            return nil
        }

        try await withArchiveApp(snapshot: snapshot, archive: FakeArchiveClient(), broadcaster: broadcaster) { app in
            try await app.testing().test(.HEAD, "/v1.51/containers/web/archive?path=/etc/hosts") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event == nil)
    }
}

// MARK: - Helpers

private func withArchiveApp(
    snapshot: ContainerSnapshot,
    archive: FakeArchiveClient,
    broadcaster: EventBroadcaster,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = broadcaster
        try app.register(
            collection: ContainerArchiveRoute(
                containerClient: StaticSnapshotClientMock(snapshot: snapshot),
                archiveClient: archive
            ))
        try await test(app)
    }
}

private func withTimeout<T>(_ task: Task<T, Never>) async -> T {
    let timeout = Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
    }
    let value = await task.value
    timeout.cancel()
    return value
}

private struct FakeArchiveClient: ClientArchiveProtocol {
    var getResult: Result<Void, ClientArchiveError> = .success(())

    func getRootfsPath(containerId: String) -> URL {
        URL(fileURLWithPath: "/nonexistent/rootfs.ext4")
    }

    func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat) {
        if case .failure(let error) = getResult { throw error }
        return (
            Data("fake-tar".utf8),
            PathStat(name: "hosts", size: 8, mode: 0o644, mtime: "2026-01-01T00:00:00Z", linkTarget: nil)
        )
    }

    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {}

    func exportRootfs(containerId: String) async throws -> URL {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }
}
