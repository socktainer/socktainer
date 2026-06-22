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

    @Test("image delete event carries normalized reference, not raw user input")
    func imageDeleteEventPopulatesFromField() async throws {
        // Raw input "alpine:latest" — the mock returns the normalized form to simulate
        // what ClientImageService.delete() does after the IMG-002 fix.
        let rawRef = "alpine:latest"
        let normalizedRef = "docker.io/library/alpine:latest"
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "remove" && event.Type == "image" {
                return event
            }
            return nil
        }

        try await withImageRouteApp(broadcaster: broadcaster) { app in
            try await app.testing().test(
                .DELETE,
                "/v1.51/images/\(rawRef)"
            ) { res async in
                #expect(res.status == .ok)
            }
        }

        // Race captureTask against a 1-second timeout. Cancelling before awaiting the
        // value can race with event delivery and produce a flaky nil result.
        let event = await withTaskGroup(of: DockerEvent?.self) { group in
            group.addTask { await captureTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        captureTask.cancel()
        // Must use result.untagged (normalized) — not the raw imageRef from the request.
        // If someone reverts the route to broadcast imageRef directly, this assertion fails.
        #expect(event?.from == normalizedRef)
        #expect(event?.Actor.Attributes["image"] == normalizedRef)
    }
}

// MARK: - Helpers

private func withImageRouteApp(
    broadcaster: EventBroadcaster,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = broadcaster
        try app.register(collection: ImageDeleteRoute(client: ImageDeleteMock()))
        try await test(app)
    }
}

private struct ImageDeleteMock: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        // Simulate normalization: prepend registry+org so the returned ref differs from
        // the raw input. The route must use result.untagged, not the original id parameter.
        ImageDeletionResult(untagged: "docker.io/library/\(id)", deletedDigest: nil)
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
