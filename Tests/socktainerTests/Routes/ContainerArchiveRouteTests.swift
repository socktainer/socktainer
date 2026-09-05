import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("ContainerArchiveRoute")
struct ContainerArchiveRouteTests {

    @Test("GET returns the tar body with the path-stat header")
    func getReturnsTarAndStatHeader() async throws {
        let archive = FakeArchiveClient(
            getResult: .success(
                (
                    Data("fake-tar".utf8),
                    PathStat(name: "passwd", size: 19, mode: 0o644, mtime: "2026-01-01T00:00:00Z", linkTarget: "")
                )))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withArchiveApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/archive?path=/etc/passwd") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == HTTPMediaType(type: "application", subType: "x-tar"))
                #expect(res.headers.first(name: "X-Docker-Container-Path-Stat") != nil)
                #expect(Data(buffer: res.body) == Data("fake-tar".utf8))
            }
        }
    }

    @Test("HEAD returns only the path-stat header with an empty body")
    func headReturnsStatHeaderOnly() async throws {
        let archive = FakeArchiveClient(
            getResult: .success(
                (
                    Data("fake-tar".utf8),
                    PathStat(name: "passwd", size: 19, mode: 0o644, mtime: "2026-01-01T00:00:00Z", linkTarget: "")
                )))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withArchiveApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.HEAD, "/v1.51/containers/web/archive?path=/etc/passwd") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "X-Docker-Container-Path-Stat") != nil)
                #expect(res.body.readableBytes == 0)
            }
        }
    }

    @Test("GET on an unknown container returns 404")
    func unknownContainer() async throws {
        let archive = FakeArchiveClient(
            getResult: .success(
                (
                    Data("fake-tar".utf8),
                    PathStat(name: "passwd", size: 19, mode: 0o644, mtime: "2026-01-01T00:00:00Z", linkTarget: "")
                )))

        try await withArchiveApp(snapshot: nil, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/ghost/archive?path=/etc/passwd") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("a missing path in the container maps to 404")
    func missingPath() async throws {
        let archive = FakeArchiveClient(getResult: .failure(.pathNotFound(path: "/nonexistent")))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withArchiveApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/archive?path=/nonexistent") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("a missing rootfs maps to 404")
    func missingRootfs() async throws {
        let archive = FakeArchiveClient(getResult: .failure(.rootfsNotFound(id: "web")))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withArchiveApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/archive?path=/etc/passwd") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an unexpected archive failure maps to 500")
    func unexpectedFailure() async throws {
        let archive = FakeArchiveClient(getResult: .failure(.operationFailed(message: "corrupted filesystem")))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)

        try await withArchiveApp(snapshot: snapshot, archive: archive) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/archive?path=/etc/passwd") { res async in
                #expect(res.status == .internalServerError)
            }
        }
    }
}

// MARK: - Helpers

private func withArchiveApp(
    snapshot: ContainerSnapshot?,
    archive: FakeArchiveClient,
    test: @escaping (Application) async throws -> Void
) async throws {
    let client: ClientContainerProtocol = snapshot.map { FixedSnapshotClientMock(snapshot: $0) } ?? EmptyClientMock()
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ContainerArchiveRoute(containerClient: client, archiveClient: archive))
        try await test(app)
    }
}

private struct FakeArchiveClient: ClientArchiveProtocol {
    var getResult: Result<(tarData: Data, stat: PathStat), ClientArchiveError>

    func getRootfsPath(containerId: String) -> URL {
        URL(fileURLWithPath: "/nonexistent/rootfs.ext4")
    }

    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat) {
        if case .failure(let error) = getResult { throw error }
        if case .success(let value) = getResult { return value }
        throw ClientArchiveError.operationFailed(message: "unreachable")
    }

    func statPath(container: ContainerSnapshot, path: String) async throws -> PathStat {
        if case .failure(let error) = getResult { throw error }
        if case .success(let value) = getResult { return value.stat }
        throw ClientArchiveError.operationFailed(message: "unreachable")
    }

    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {}

    func exportRootfs(containerId: String) async throws -> URL {
        throw ClientArchiveError.operationFailed(message: "not under test")
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
