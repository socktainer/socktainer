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

    @Test("image delete event carries image reference in 'from' field")
    func imageDeleteEventPopulatesFromField() async throws {
        let imageRef = "alpine:latest"
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
                "/v1.51/images/\(imageRef)"
            ) { res async in
                #expect(res.status == .ok)
            }
        }

        captureTask.cancel()  // unblock the for-await if the event was never emitted
        let event = await captureTask.value
        #expect(event?.from == imageRef)
        #expect(event?.Actor.Attributes["image"] == imageRef)
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
    func delete(id: String) async throws {}
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
