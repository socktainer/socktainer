import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// DELETE /images/{name} for a dangling image must return only a {Deleted}
/// record. moby gates the {Untagged} entry on !isDanglingImage — a dangling
/// image has no real tag, so echoing `Untagged: "<none>…"` puts a garbage
/// line in `docker rmi` output. The route already suppresses the "untag"
/// event for dangling images; the response must match.
@Suite("ImageDeleteRoute — dangling image response shape")
struct ImageDeleteDanglingResponseTests {

    @Test(
        "Deleting a dangling image returns only the Deleted record",
        arguments: [
            // The sentinel LocalOCILayoutClient assigns to a loaded tarball with no RepoTags.
            "untagged@sha256:aaa111",
            // A ref imported verbatim from a foreign tarball's name annotation.
            "<none>:<none>",
        ])
    func danglingDeleteOmitsUntagged(untaggedRef: String) async throws {
        let result = ImageDeletionResult(
            untagged: untaggedRef,
            digest: "sha256:aaa111",
            deletedDigest: "sha256:aaa111"
        )

        let items = try await Self.deleteImage(result: result, ref: "sha256:aaa111")
        #expect(items.map(\.Deleted) == ["sha256:aaa111"])
        #expect(items.compactMap(\.Untagged).isEmpty, "A dangling image has no tag to untag")
    }

    @Test("Deleting a pull-by-digest image keeps its Untagged record (not dangling)")
    func digestRefKeepsUntagged() async throws {
        let result = ImageDeletionResult(
            untagged: "docker.io/library/alpine@sha256:ddd444",
            digest: "sha256:ddd444",
            deletedDigest: "sha256:ddd444"
        )

        let items = try await Self.deleteImage(result: result, ref: "alpine@sha256:ddd444")
        #expect(items.compactMap(\.Untagged) == ["docker.io/library/alpine@sha256:ddd444"])
    }

    @Test("Deleting a tagged image still returns Untagged (and Deleted when layers are freed)")
    func taggedDeleteKeepsUntagged() async throws {
        let result = ImageDeletionResult(
            untagged: "docker.io/library/alpine:latest",
            digest: "sha256:bbb222",
            deletedDigest: "sha256:bbb222"
        )

        let items = try await Self.deleteImage(result: result, ref: "alpine:latest")
        #expect(items.compactMap(\.Untagged) == ["docker.io/library/alpine:latest"])
        #expect(items.compactMap(\.Deleted) == ["sha256:bbb222"])
    }

    @Test("Untag-only delete (other tags remain) returns just the Untagged record")
    func untagOnlyDelete() async throws {
        let result = ImageDeletionResult(
            untagged: "docker.io/library/alpine:extra",
            digest: "sha256:ccc333",
            deletedDigest: nil
        )

        let items = try await Self.deleteImage(result: result, ref: "alpine:extra")
        #expect(items.compactMap(\.Untagged) == ["docker.io/library/alpine:extra"])
        #expect(items.compactMap(\.Deleted).isEmpty)
    }

    // MARK: - Helpers

    private static func deleteImage(result: ImageDeletionResult, ref: String) async throws -> [ImageDeleteResponseItem] {
        var items: [ImageDeleteResponseItem] = []
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ImageDeleteRoute(client: FixedResultImageMock(result: result)))

            try await app.testing().test(.DELETE, "/v1.51/images/\(ref)") { res async throws in
                #expect(res.status == .ok)
                items = try JSONDecoder().decode([ImageDeleteResponseItem].self, from: Data(buffer: res.body))
            }
        }
        return items
    }
}

// MARK: - Mocks

/// Mock whose delete always returns a fixed ImageDeletionResult.
private struct FixedResultImageMock: ClientImageProtocol {
    let result: ImageDeletionResult
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult { result }
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
        URL(fileURLWithPath: "/dev/null")
    }
}
