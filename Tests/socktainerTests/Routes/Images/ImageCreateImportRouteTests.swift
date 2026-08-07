import ContainerAPIClient
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// moby validates `repo`/`tag` (`httputils.RepoTagReference`) before the layer reader
/// is even constructed (api/server/router/image/image_routes.go's `postImagesCreate`),
/// so a digest reference is rejected without reading the request body at all.
@Suite("ImageCreateRoute — docker import fail-fast")
struct ImageCreateImportRouteTests {

    @Test("a digest reference in repo is rejected without the body ever being read")
    func digestReferenceRejectedBeforeBodyIsRead() async throws {
        let client = SpyImageClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
            try app.register(collection: ImageCreateRoute(client: client))

            let hugeGarbageBody = ByteBuffer(repeating: 0xFF, count: 10_000_000)
            try await app.testing().test(
                .POST, "/v1.51/images/create?fromSrc=-&repo=foo@sha256:\(String(repeating: "a", count: 64))",
                body: hugeGarbageBody
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cannot reference"))
            }
        }

        #expect(!(await client.importImageWasCalled), "importImage must not run when repo is a digest reference")
    }

    @Test("a malformed (non-digest) reference in repo is also rejected without the body ever being read")
    func malformedReferenceRejectedBeforeBodyIsRead() async throws {
        let client = SpyImageClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
            try app.register(collection: ImageCreateRoute(client: client))

            // "UPPERCASE" fails Reference.parse's path grammar (lowercase alnum
            // only) — a malformed reference the old digest-only check would not
            // have caught before reading the body.
            let hugeGarbageBody = ByteBuffer(repeating: 0xFF, count: 10_000_000)
            try await app.testing().test(
                .POST, "/v1.51/images/create?fromSrc=-&repo=UPPERCASE",
                body: hugeGarbageBody
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("invalid reference format"))
            }
        }

        #expect(!(await client.importImageWasCalled), "importImage must not run when repo is malformed")
    }
}

@Suite("ImageCreateRoute — pull platform policy")
struct ImageCreatePullPlatformTests {
    @Test("an invalid pull platform is a Docker 400 and never reaches the client")
    func invalidPlatformIsBadRequest() async throws {
        let client = SpyImageClient()
        try await withImageCreateApp(client: client) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/create?fromImage=alpine&platform=linux%2Farm64%2Fextra%2Fsegment"
            ) { response async in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("invalid platform"))
            }
        }
        #expect(await client.pullRequests.isEmpty)
    }

    @Test("an explicit pull platform is strict")
    func explicitPlatformIsStrict() async throws {
        let client = SpyImageClient()
        try await withImageCreateApp(client: client) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/create?fromImage=alpine&platform=linux%2Farm64"
            ) { response async in
                #expect(response.status == .ok)
            }
        }
        let request = try #require(await client.pullRequests.last)
        #expect(request.platform == Platform(arch: "arm64", os: "linux"))
        #expect(request.fallbackPolicy == .strict)
    }

    @Test("an implicit host-default pull may use Rosetta fallback")
    func implicitPlatformAllowsFallback() async throws {
        let client = SpyImageClient()
        try await withImageCreateApp(client: client) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/create?fromImage=alpine"
            ) { response async in
                #expect(response.status == .ok)
            }
        }
        let request = try #require(await client.pullRequests.last)
        #expect(request.platform == currentPlatform())
        #expect(request.fallbackPolicy == .allowRosetta)
    }

    private func withImageCreateApp(
        client: SpyImageClient,
        operation: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ImageCreateRoute(client: client))
            try await operation(app)
        }
    }
}

private actor SpyImageClient: ClientImageProtocol {
    private(set) var importImageWasCalled = false
    private(set) var pullRequests: [(platform: Platform, fallbackPolicy: PlatformFallbackPolicy)] = []

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, fallbackPolicy: PlatformFallbackPolicy, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        pullRequests.append((platform, fallbackPolicy))
        return AsyncThrowingStream<PullProgress, Error> { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        FileManager.default.temporaryDirectory
    }
    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String],
        platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        importImageWasCalled = true
        return (repo, "sha256:" + String(repeating: "b", count: 64))
    }
}
