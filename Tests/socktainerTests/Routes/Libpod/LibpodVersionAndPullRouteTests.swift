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

    /// `podman pull --platform linux/amd64` sends `arch=amd64&os=linux`, not `platform`; ignoring
    /// them pulled the host's arm64 variant instead.
    @Test("pull honours podman's os/arch/variant query parameters")
    func pullHonoursArchOsVariant() async throws {
        let client = RecordingPullClient()
        try await withLibpodApp { app in
            try app.register(collection: LibpodImagePullRoute(client: client, systemConfig: ContainerSystemConfig()))
            try await app.testing().test(.POST, "/v5.0.0/libpod/images/pull?reference=alpine:latest&arch=amd64&os=linux") { res async throws in
                #expect(res.status == .ok)
            }
        }
        let platform = try #require(client.platforms.first)
        #expect(platform.os == "linux")
        #expect(platform.architecture == "amd64")
    }

    @Test("os/arch/variant map onto a platform; a part left out defaults to the host's")
    func requestedPlatformFromParts() throws {
        let armV7 = try LibpodImagePullRoute.requestedPlatform(platform: nil, os: "linux", arch: "arm", variant: "v7")
        #expect(armV7 == (try Platform(from: "linux/arm/v7")))
        let archOnly = try LibpodImagePullRoute.requestedPlatform(platform: nil, os: nil, arch: "s390x", variant: nil)
        #expect(archOnly == (try Platform(from: "\(Platform.current.os)/s390x")))
        let none = try LibpodImagePullRoute.requestedPlatform(platform: nil, os: "", arch: "", variant: "")
        #expect(none == Platform.current)
        let explicit = try LibpodImagePullRoute.requestedPlatform(platform: "linux/amd64", os: nil, arch: "s390x", variant: nil)
        #expect(explicit.architecture == "amd64")
        #expect(throws: Abort.self) {
            try LibpodImagePullRoute.requestedPlatform(platform: nil, os: "plan9", arch: "amd64", variant: nil)
        }
    }
}

private final class RecordingPullClient: ClientImageProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Platform] = []
    var platforms: [Platform] { lock.withLock { recorded } }

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        lock.withLock { recorded.append(platform) }
        return AsyncThrowingStream { $0.finish() }
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
