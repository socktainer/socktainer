import ContainerAPIClient
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `podman load --input <path>` (the local-path form, `/libpod/local/images/load`) names an
/// arbitrary absolute path on the server's own filesystem — this must reject anything that
/// isn't a regular file (directories, FIFOs, sockets, device files) before ever handing the
/// path to `client.load`, which would otherwise try to read it as a tar archive: a FIFO in
/// particular can hang the read waiting for a writer that never comes.
@Suite("LibpodImagesLoadRoute — local path validation")
struct LibpodImagesLoadRouteTests {
    @Test("a directory path is rejected with a client error, not passed to client.load")
    func directoryPathIsRejected() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let client = StubImageLoadClient()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImagesLoadRoute(client: client))

            let encodedPath = tmp.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tmp.path
            try await app.testing().test(.POST, "/v1.51/libpod/local/images/load?path=\(encodedPath)") { res async in
                #expect(res.status == .badRequest)
            }
        }
        #expect(!(await client.loadWasCalled))
    }

    @Test("a FIFO path is rejected with a client error, not passed to client.load")
    func fifoPathIsRejected() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fifoPath = tmp.appendingPathComponent("a-fifo").path
        try #require(mkfifo(fifoPath, 0o644) == 0)

        let client = StubImageLoadClient()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodImagesLoadRoute(client: client))

            let encodedPath = fifoPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fifoPath
            try await app.testing().test(.POST, "/v1.51/libpod/local/images/load?path=\(encodedPath)") { res async in
                #expect(res.status == .badRequest)
            }
        }
        #expect(!(await client.loadWasCalled))
    }
}

private actor StubImageLoadClient: ClientImageProtocol {
    private(set) var loadWasCalled = false

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func pushManifestList(reference: String, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] {
        loadWasCalled = true
        return []
    }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        FileManager.default.temporaryDirectory
    }
    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String],
        platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        (repo, "sha256:" + String(repeating: "b", count: 64))
    }
}
