import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Route-level coverage for `podman manifest push` (both the current path-destination form and
/// the legacy query-destination form), and specifically the retag-before-push /
/// untag-after-push dance `LibpodManifestPushRoute` is responsible for driving.
@Suite("LibpodManifestPushRoute")
struct LibpodManifestPushRouteTests {
    @Test("destination equal to name pushes directly, without retagging or later untagging")
    func sameDestinationSkipsRetag() async throws {
        let recorder = CallRecorder()
        let pushedReference = Box<String?>(nil)
        let manifestClient = MockManifestClient(
            recorder: recorder,
            digestHandler: { _ in "sha256:finaldigest" },
            retagForPushHandler: { name, _ in (name, nil) }
        )
        let imageClient = StubImageClient(pushManifestListHandler: { reference in
            await pushedReference.set(reference)
            return AsyncThrowingStream { $0.finish() }
        })

        try await withPushApp(manifestClient: manifestClient, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist/registry/mylist") { res async throws in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("sha256:finaldigest"))
            }
        }
        #expect(await pushedReference.get() == "mylist")
        let calls = await recorder.calls
        #expect(!calls.contains { $0.hasPrefix("untagPushDestination") })
    }

    @Test("a differing destination retags first, pushes the retagged reference, then untags")
    func differingDestinationRetagsPushesUntags() async throws {
        let recorder = CallRecorder()
        let pushedReference = Box<String?>(nil)
        let manifestClient = MockManifestClient(
            recorder: recorder,
            digestHandler: { _ in "sha256:finaldigest" },
            retagForPushHandler: { name, destination in
                (destination, RetagState(reference: destination, priorDescriptor: nil))
            },
            untagPushDestinationHandler: { _ in }
        )
        let imageClient = StubImageClient(
            recorder: recorder,
            pushManifestListHandler: { reference in
                await pushedReference.set(reference)
                return AsyncThrowingStream { $0.finish() }
            })

        try await withPushApp(manifestClient: manifestClient, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist/registry/registry.example.com/repo:tag") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await pushedReference.get() == "registry.example.com/repo:tag")

        let calls = await recorder.calls
        let retagIndex = calls.firstIndex { $0.hasPrefix("retagForPush") }
        let pushIndex = calls.firstIndex { $0.hasPrefix("pushManifestList") }
        let untagIndex = calls.firstIndex { $0.hasPrefix("untagPushDestination") }
        #expect(retagIndex != nil)
        #expect(pushIndex != nil)
        #expect(untagIndex != nil)
        if let retagIndex, let pushIndex, let untagIndex {
            #expect(retagIndex < pushIndex, "retag must happen before the network push")
            #expect(pushIndex < untagIndex, "the network push must happen before untag")
        }
    }

    @Test("the legacy ?destination= query form behaves the same as the path form")
    func legacyQueryDestinationForm() async throws {
        let pushedReference = Box<String?>(nil)
        let manifestClient = MockManifestClient(
            digestHandler: { _ in "sha256:finaldigest" },
            retagForPushHandler: { name, _ in (name, nil) }
        )
        let imageClient = StubImageClient(pushManifestListHandler: { reference in
            await pushedReference.set(reference)
            return AsyncThrowingStream { $0.finish() }
        })

        try await withPushApp(manifestClient: manifestClient, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist/push?destination=mylist") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await pushedReference.get() == "mylist")
    }

    @Test("a missing destination on the legacy query form is a 400")
    func missingQueryDestinationIs400() async throws {
        try await withPushApp(manifestClient: MockManifestClient(), imageClient: StubImageClient()) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist/push") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a source manifest list that can't be found is a 404")
    func retagNotFoundIs404() async throws {
        let manifestClient = MockManifestClient(retagForPushHandler: { name, _ in
            throw ClientImageError.notFound(id: name)
        })

        try await withPushApp(manifestClient: manifestClient, imageClient: StubImageClient()) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/ghost/registry/dest") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("a push failure still untags the destination before surfacing the error")
    func pushFailureStillUntags() async throws {
        let recorder = CallRecorder()
        let manifestClient = MockManifestClient(
            recorder: recorder,
            retagForPushHandler: { _, destination in
                (destination, RetagState(reference: destination, priorDescriptor: nil))
            },
            untagPushDestinationHandler: { _ in }
        )
        let imageClient = StubImageClient(pushManifestListHandler: { _ in
            throw ClientImageError.notFound(id: "registry.example.com/repo:tag")
        })

        try await withPushApp(manifestClient: manifestClient, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist/registry/registry.example.com/repo:tag") { res async throws in
                #expect(res.status == .notFound)
            }
        }
        let calls = await recorder.calls
        #expect(calls.contains { $0.hasPrefix("untagPushDestination") })
    }

    @Test("a failure mid-stream (after the push started) still untags the destination")
    func midStreamFailureStillUntags() async throws {
        let recorder = CallRecorder()
        let manifestClient = MockManifestClient(
            recorder: recorder,
            retagForPushHandler: { _, destination in
                (destination, RetagState(reference: destination, priorDescriptor: nil))
            },
            untagPushDestinationHandler: { _ in }
        )
        let imageClient = StubImageClient(
            recorder: recorder,
            pushManifestListHandler: { _ in
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ClientImageError.notFound(id: "registry.example.com/repo:tag"))
                }
            })

        try await withPushApp(manifestClient: manifestClient, imageClient: imageClient) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist/registry/registry.example.com/repo:tag") { res async throws in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("error"))
            }
        }

        // This cleanup runs in its own untied Task (see LibpodManifestPushRoute — deliberately
        // NOT a structured child of the response-stream Task, so it survives that Task being
        // cancelled on a client disconnect), so it isn't guaranteed to have completed the
        // instant the response body finishes draining — poll briefly rather than asserting
        // immediately.
        var sawUntag = false
        for _ in 0..<50 {
            if await recorder.calls.contains(where: { $0.hasPrefix("untagPushDestination") }) {
                sawUntag = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sawUntag)
    }

    // MARK: - Helpers

    private func withPushApp(
        manifestClient: MockManifestClient, imageClient: StubImageClient, test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodManifestPushRoute(manifestClient: manifestClient, imageClient: imageClient))
            try await test(app)
        }
    }
}

/// A `ClientImageProtocol` stub exposing only `pushManifestList` as configurable — every other
/// method is unused by `LibpodManifestPushRoute` and stubbed to a harmless default.
private struct StubImageClient: ClientImageProtocol {
    var recorder: CallRecorder?
    var pushManifestListHandler: (@Sendable (String) async throws -> AsyncThrowingStream<String, Error>)?

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult { ImageDeletionResult(untagged: id, digest: "sha256:0000", deletedDigest: nil) }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func pushManifestList(reference: String, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        await recorder?.record("pushManifestList(\(reference))")
        guard let pushManifestListHandler else { return AsyncThrowingStream { $0.finish() } }
        return try await pushManifestListHandler(reference)
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }
    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String], platform: Platform,
        appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        (nil, "sha256:0000000000000000000000000000000000000000000000000000000000000000")
    }
}
