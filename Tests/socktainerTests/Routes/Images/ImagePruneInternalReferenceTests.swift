import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("ImagePruneRoute internal reference visibility")
struct ImagePruneInternalReferenceTests {
    @Test(
        "internal dangling and runtime lease cleanup emits only a digest delete",
        arguments: [
            "moby-dangling@sha256:" + String(repeating: "a", count: 64),
            ContainerImageLease.reference(
                for: "sha256:" + String(repeating: "a", count: 64)
            ),
        ]
    )
    func internalCleanupNeverLeaksUntagged(reference: String) async throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let result = ImageDeletionResult(
            untagged: reference,
            digest: digest,
            deletedDigest: digest,
            reclaimedBytes: 4_096
        )
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let firstImageEvent = Task<DockerEvent?, Never> {
            for await event in stream where event.Type == "image" {
                return event
            }
            return nil
        }
        var response: RESTImagePruneResponse?

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(
                collection: ImagePruneRoute(
                    client: FixedPruneResultImageClient(result: result)
                )
            )

            try await app.testing().test(
                .POST,
                "/v1.51/images/prune"
            ) { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(
                    RESTImagePruneResponse.self
                )
            }
        }

        let event = await firstImageEvent.value
        #expect(event?.Action == "delete")
        #expect(event?.Actor.ID == digest)
        #expect(event?.Actor.Attributes["name"] == digest)
        #expect(event?.Actor.Attributes["name"] != reference)
        #expect(response?.ImagesDeleted?.count == 1)
        #expect(response?.ImagesDeleted?.first?.Deleted == digest)
        #expect(response?.ImagesDeleted?.first?.Untagged == nil)
        #expect(response?.SpaceReclaimed == 4_096)
    }
}

private struct FixedPruneResultImageClient: ClientImageProtocol {
    let result: ImageDeletionResult

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }

    func delete(id: String) async throws -> ImageDeletionResult {
        result
    }

    func pull(
        image: String,
        tag: String?,
        platform: Platform,
        fallbackPolicy: PlatformFallbackPolicy,
        logger: Logger
    ) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func push(
        reference: String,
        platform: Platform?,
        logger: Logger
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func prune(
        filters: [String: [String]],
        logger: Logger
    ) async throws -> (
        results: [ImageDeletionResult], spaceReclaimed: Int64
    ) {
        ([result], result.reclaimedBytes)
    }

    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> [String] { [] }

    func save(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }

    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        (nil, result.digest)
    }
}
