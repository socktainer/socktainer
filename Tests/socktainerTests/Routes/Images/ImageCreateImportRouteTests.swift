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
}

private actor SpyImageClient: ClientImageProtocol {
    private(set) var importImageWasCalled = false

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
        importImageWasCalled = true
        return (repo, "sha256:" + String(repeating: "b", count: 64))
    }
}
