import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("LibpodVersionRoute / LibpodImagePullRoute")
struct LibpodVersionAndPullRouteTests {
    private func withLibpodApp(_ body: (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try await body(app)
        }
    }

    /// podman shows the server's API version from the `Podman Engine` component; without it,
    /// `podman version` reports the Docker API version instead of the one `/_ping` advertises.
    @Test("version carries a Podman Engine component with the advertised libpod API version")
    func versionHasPodmanEngine() async throws {
        try await withLibpodApp { app in
            try app.register(collection: LibpodVersionRoute())
            try await app.testing().test(.GET, "/v5.0.0/libpod/version") { res async throws in
                #expect(res.status == .ok)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                let components = try #require(body["Components"] as? [[String: Any]])
                let engine = try #require(components.first { $0["Name"] as? String == "Podman Engine" })
                #expect((engine["Details"] as? [String: Any])?["APIVersion"] as? String == LibpodSupport.apiVersion)
            }
        }
    }

    @Test("a failed pull ends the stream cleanly after its error frame")
    func failedPullEndsCleanly() async throws {
        try await withLibpodApp { app in
            try app.register(collection: LibpodImagePullRoute(client: FailingPullClient(), systemConfig: ContainerSystemConfig()))
            try await app.testing().test(.POST, "/v5.0.0/libpod/images/pull?reference=alpine:latest") { res async throws in
                #expect(res.status == .ok)
                let lines = res.body.string.split(separator: "\n")
                let last = try #require(lines.last)
                let frame = try #require(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
                #expect(frame["error"] as? String == "registry unreachable")
            }
        }
    }
}

private struct PullFailure: LocalizedError {
    var errorDescription: String? { "registry unreachable" }
}

private struct FailingPullClient: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: PullFailure()) }
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
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
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
