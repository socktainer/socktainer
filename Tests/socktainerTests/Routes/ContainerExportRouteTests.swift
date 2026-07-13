import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("ContainerExportRoute")
struct ContainerExportRouteTests {

    @Test("streams the rootfs tar as octet-stream and deletes the temp file afterwards")
    func exportStreamsTar() async throws {
        let tarBytes = Data("fake-rootfs-tar-content".utf8)
        let archive = FakeArchiveClient(exportResult: .success(tarBytes))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withExportApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/export") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == HTTPMediaType(type: "application", subType: "octet-stream"))
                #expect(Data(buffer: res.body) == tarBytes)
            }
        }

        let exportedFile = await archive.lastExportedFile()
        let cleaned = try await pollUntil(timeoutSeconds: 3) {
            exportedFile.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        #expect(cleaned, "the temp tar must be deleted once streaming completes")
    }

    @Test("a completed export broadcasts a container 'export' event like moby")
    func exportEmitsEvent() async throws {
        let archive = FakeArchiveClient(exportResult: .success(Data("tar".utf8)))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "export" && event.Type == "container" {
                return event
            }
            return nil
        }

        try await withExportApp(snapshot: snapshot, archive: archive, broadcaster: broadcaster) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/export") { res async in
                #expect(res.status == .ok)
            }
        }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            captureTask.cancel()
        }
        let event = await captureTask.value
        timeout.cancel()

        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["name"] == "web")
    }

    @Test("unknown container returns 404")
    func unknownContainer() async throws {
        let archive = FakeArchiveClient(exportResult: .success(Data()))
        try await withExportApp(snapshot: nil, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/ghost/export") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("a missing rootfs returns 404")
    func missingRootfs() async throws {
        let archive = FakeArchiveClient(exportResult: .failure(.rootfsNotFound(id: "web")))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        try await withExportApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/export") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an ambiguous container reference is rejected with 400")
    func ambiguousReference() async throws {
        let archive = FakeArchiveClient(exportResult: .failure(.operationFailed(message: "not under test")))
        try await withExportApp(snapshot: nil, archive: archive, containerClient: AmbiguousClientMock(reference: "web", matches: ["web1", "web2"])) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/export") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("ambiguous container reference web"))
            }
        }
    }

    @Test("an export failure surfaces as 500 with moby's message shape")
    func exportFailure() async throws {
        let archive = FakeArchiveClient(exportResult: .failure(.operationFailed(message: "corrupted superblock")))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        try await withExportApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/export") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("Error exporting container web"))
            }
        }
    }
}

// MARK: - Helpers

private func withExportApp(
    snapshot: ContainerSnapshot?,
    archive: FakeArchiveClient,
    broadcaster: EventBroadcaster? = nil,
    containerClient: ClientContainerProtocol? = nil,
    test: @escaping (Application) async throws -> Void
) async throws {
    let client: ClientContainerProtocol =
        containerClient ?? snapshot.map { FixedSnapshotClientMock(snapshot: $0) } ?? EmptyClientMock()
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        if let broadcaster {
            app.storage[EventBroadcasterKey.self] = broadcaster
        }
        try app.register(collection: ContainerExportRoute(containerClient: client, archiveClient: archive))
        try await test(app)
    }
}

private actor FakeArchiveClient: ClientArchiveProtocol {
    private let exportResult: Result<Data, ClientArchiveError>
    private var exportedFile: URL?

    init(exportResult: Result<Data, ClientArchiveError>) {
        self.exportResult = exportResult
    }

    func lastExportedFile() -> URL? { exportedFile }

    nonisolated func getRootfsPath(containerId: String) -> URL {
        URL(fileURLWithPath: "/nonexistent/rootfs.ext4")
    }

    func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat) {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func exportRootfs(containerId: String) async throws -> URL {
        switch exportResult {
        case .failure(let error):
            throw error
        case .success(let data):
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString).tar")
            try data.write(to: url)
            exportedFile = url
            return url
        }
    }
}

private struct FixedSnapshotClientMock: ClientContainerProtocol {
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
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}

private struct AmbiguousClientMock: ClientContainerProtocol {
    let reference: String
    let matches: [String]

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        throw ClientContainerError.ambiguousId(reference: reference, matches: matches)
    }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}

private struct EmptyClientMock: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
