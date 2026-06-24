import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("ImageDeleteRoute — event 'from' field")
struct ImageDeleteEventTests {

    @Test("image untag event uses the digest as Actor.ID and the normalized ref as name (moby shape)")
    func imageDeleteEventPopulatesFromField() async throws {
        // Raw input "alpine:latest"; the mock returns the normalized ref + a known digest,
        // simulating ClientImageService.delete(). moby's untag event sets Actor.ID to the
        // image digest with the reference in the `name` attribute and no `image` key.
        let rawRef = "alpine:latest"
        let normalizedRef = "docker.io/library/alpine:latest"
        let digest = "sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "untag" && event.Type == "image" {
                return event
            }
            return nil
        }

        try await withImageRouteApp(broadcaster: broadcaster, digest: digest) { app in
            try await app.testing().test(
                .DELETE,
                "/v1.51/images/\(rawRef)"
            ) { res async in
                #expect(res.status == .ok)
            }
        }

        // Bound the wait with a timeout that cancels the capture task so its for-await
        // loop exits cleanly even if the event never arrives.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            captureTask.cancel()
        }
        let event = await captureTask.value
        timeout.cancel()

        #expect(event?.Actor.ID == digest)
        #expect(event?.Actor.Attributes["name"] == normalizedRef)
        #expect(event?.Actor.Attributes["image"] == nil, "moby image events carry no 'image' attribute")
        #expect(event?.from == "")
    }
}

// MARK: - Helpers

private func withImageRouteApp(
    broadcaster: EventBroadcaster,
    digest: String = "sha256:abc",
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = broadcaster
        try app.register(collection: ImageDeleteRoute(client: ImageDeleteMock(digest: digest)))
        try await test(app)
    }
}

private struct ImageDeleteMock: ClientImageProtocol {
    var digest: String = "sha256:abc"
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        // Simulate normalization: prepend registry+org so the returned ref differs from
        // the raw input. The route must use result.untagged, not the original id parameter.
        ImageDeletionResult(untagged: "docker.io/library/\(id)", digest: digest, deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (
        deletedImages: [String], spaceReclaimed: Int64
    ) { ([], 0) }
    func load(
        tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> [String] { [] }
    func save(
        references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> URL { URL(fileURLWithPath: "/tmp") }
}
