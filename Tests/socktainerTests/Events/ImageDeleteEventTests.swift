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

    // moby's imageDeleteHelper skips ActionUnTag when isDanglingImage(img) — dangling images
    // have no real tag to untag (Name == "<none>"). Verified against moby v28.5.2 source:
    // daemon/containerd/image_delete.go `if !isDanglingImage(img) { logImageEvent(...ActionUnTag) }`.
    @Test("dangling image delete emits 'delete' only — no 'untag'")
    func danglingImageDeleteEmitsDeleteOnly() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        var collected: [DockerEvent] = []
        let captureTask = Task<[DockerEvent], Never> {
            for await event in stream where event.Type == "image" {
                collected.append(event)
                // Collect for 300ms then return
                if collected.count >= 1 { break }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            return collected
        }

        // Mock returns a dangling reference ("<none>@sha256:...") with a deletedDigest —
        // the delete event only fires when deletedDigest is non-nil, so this is required.
        let danglingMock = DanglingImageDeleteMock()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ImageDeleteRoute(client: danglingMock))
            try await app.testing().test(.DELETE, "/v1.51/images/sha256:abc123") { res async in
                #expect(res.status == .ok)
            }
        }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            captureTask.cancel()
        }
        let events = await captureTask.value
        timeout.cancel()

        let untagEvents = events.filter { $0.Action == "untag" }
        let deleteEvents = events.filter { $0.Action == "delete" }
        #expect(untagEvents.isEmpty, "dangling image delete must emit no 'untag' event")
        #expect(!deleteEvents.isEmpty, "dangling image delete must emit a 'delete' event")
    }

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

private struct DanglingImageDeleteMock: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        // A dangling image has Name == "<none>" in Apple Container (mirrors moby).
        // The route must skip "untag" and only emit "delete" for this case.
        ImageDeletionResult(untagged: "<none>@sha256:abc123", digest: "sha256:abc123", deletedDigest: "sha256:abc123")
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws
        -> AsyncThrowingStream<String, Error>
    { AsyncThrowingStream { $0.finish() } }
    func push(reference: String, platform: Platform?, logger: Logger) async throws
        -> AsyncThrowingStream<String, Error>
    { AsyncThrowingStream { $0.finish() } }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (
        results: [ImageDeletionResult], spaceReclaimed: Int64
    ) { ([], 0) }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL { URL(fileURLWithPath: "/tmp") }
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
        results: [ImageDeletionResult], spaceReclaimed: Int64
    ) { ([], 0) }
    func load(
        tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> [String] { [] }
    func save(
        references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> URL { URL(fileURLWithPath: "/tmp") }
}
