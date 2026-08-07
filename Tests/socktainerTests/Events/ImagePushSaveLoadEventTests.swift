import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// moby's push event carries the familiar reference as Actor.ID and the familiar name
/// (no tag) as `name` (daemon/containerd/image_push.go); save/load emit one event per
/// image with the digest as Actor.ID (daemon/containerd/image_exporter.go). Socktainer
/// falls back to the reference when the store cannot resolve a digest.
@Suite("Image push/save/load events")
struct ImagePushSaveLoadEventTests {

    @Test("a successful push broadcasts 'push' with the reference as Actor.ID and the familiar name")
    func pushEmitsEvent() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "push" { return event }
            return nil
        }

        try await withImageApp(client: FakeImageClient(), broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/images/alpine/push?tag=latest") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "image")
        #expect(event?.Actor.ID == "alpine:latest")
        #expect(event?.Actor.Attributes["name"] == "alpine")
    }

    @Test("a failed push broadcasts nothing")
    func failedPushStaysSilent() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "push" { return event }
            return nil
        }

        try await withImageApp(client: FakeImageClient(failPushStream: true), broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/images/alpine/push?tag=latest") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event == nil)
    }

    @Test("docker save broadcasts one 'save' per image with the digest as Actor.ID when resolvable")
    func saveEmitsPerImageWithDigest() async throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let client = FakeImageClient(images: [makeClientImage(reference: "docker.io/library/alpine:latest", digest: digest)])
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "save" { return event }
            return nil
        }

        try await withImageApp(client: client, broadcaster: broadcaster) { app in
            try await app.testing().test(.GET, "/v1.51/images/docker.io/library/alpine:latest/get") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "image")
        #expect(event?.Actor.ID == digest)
        #expect(event?.Actor.Attributes["name"] == digest)
    }

    @Test("docker save falls back to the reference when the store cannot resolve a digest")
    func saveFallsBackToReference() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "save" { return event }
            return nil
        }

        try await withImageApp(client: FakeImageClient(), broadcaster: broadcaster) { app in
            try await app.testing().test(.GET, "/v1.51/images/ghost:latest/get") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event?.Actor.ID == "ghost:latest")
    }

    @Test("docker save emits the identity captured with the exported archive")
    func saveUsesAtomicArchiveIdentity() async throws {
        let exportedConfig = "sha256:" + String(repeating: "c", count: 64)
        let laterConfig = "sha256:" + String(repeating: "d", count: 64)
        let client = FakeImageClient(
            images: [
                makeClientImage(reference: "example:latest", digest: laterConfig)
            ],
            savedActorIDs: [exportedConfig]
        )
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "save" { return event }
            return nil
        }

        try await withImageApp(client: client, broadcaster: broadcaster) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/images/example:latest/get"
            ) { response async in
                #expect(response.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event?.Actor.ID == exportedConfig)
    }

    @Test("docker save removes its private export only after the response stream completes")
    func saveCleansUpCompletedStream() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let client = FakeImageClient(saveDirectory: tempDir)

        try await withImageApp(
            client: client,
            broadcaster: EventBroadcaster()
        ) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/images/example:latest/get"
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.body.string == "fake-saved-tarball")
            }
        }

        #expect(!FileManager.default.fileExists(atPath: tempDir.path))
    }

    @Test("docker save removes its export when response setup fails")
    func saveCleansUpResponseSetupFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let client = FakeImageClient(
            saveDirectory: tempDir,
            saveWritesTarball: false
        )

        try await withImageApp(
            client: client,
            broadcaster: EventBroadcaster()
        ) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/images/example:latest/get"
            ) { response async in
                #expect(response.status == .internalServerError)
            }
        }

        #expect(!FileManager.default.fileExists(atPath: tempDir.path))
    }

    @Test("docker load broadcasts one 'load' per loaded image with the digest as Actor.ID")
    func loadEmitsPerImage() async throws {
        let alpineDigest = "sha256:" + String(repeating: "b", count: 64)
        let client = FakeImageClient(
            images: [makeClientImage(reference: "docker.io/library/alpine:latest", digest: alpineDigest)],
            loadedImages: ["docker.io/library/alpine:latest", "docker.io/library/busybox:latest"]
        )
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<[DockerEvent], Never> {
            var events: [DockerEvent] = []
            for await event in stream where event.Action == "load" {
                events.append(event)
                if events.count == 2 { return events }
            }
            return events
        }

        try await withImageApp(client: client, broadcaster: broadcaster) { app in
            try await app.testing().test(
                .POST, "/v1.51/images/load",
                body: ByteBuffer(data: Data("fake-tarball".utf8))
            ) { res async in
                #expect(res.status == .ok)
            }
        }

        let events = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(events.count == 2)
        #expect(events.first?.Type == "image")
        // Resolvable reference → digest; unresolvable → the reference itself.
        #expect(events.first?.Actor.ID == alpineDigest)
        #expect(events.last?.Actor.ID == "docker.io/library/busybox:latest")
    }

    @Test("docker load emits identities captured by the completed import")
    func loadUsesAtomicArchiveIdentity() async throws {
        let importedConfig = "sha256:" + String(repeating: "e", count: 64)
        let laterConfig = "sha256:" + String(repeating: "f", count: 64)
        let reference = "docker.io/library/example:latest"
        let client = FakeImageClient(
            images: [makeClientImage(reference: reference, digest: laterConfig)],
            loadedImages: [reference],
            loadedActorIDs: [importedConfig]
        )
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "load" { return event }
            return nil
        }

        try await withImageApp(client: client, broadcaster: broadcaster) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/load",
                body: ByteBuffer(data: Data("fake-tarball".utf8))
            ) { response async in
                #expect(response.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event?.Actor.ID == importedConfig)
    }
}

// MARK: - Helpers

private func withImageApp(
    client: FakeImageClient,
    broadcaster: EventBroadcaster,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = broadcaster
        app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
        try app.register(collection: ImagePushRoute(client: client))
        try app.register(collection: ImagesGetRoute(client: client))
        try app.register(collection: ImagesLoadRoute(client: client))
        try await test(app)
    }
}

private func withTimeout<T>(_ task: Task<T, Never>) async -> T {
    let timeout = Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
    }
    let value = await task.value
    timeout.cancel()
    return value
}

private func makeClientImage(reference: String, digest: String) -> ClientImage {
    ClientImage(
        description: ImageDescription(
            reference: reference,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: digest,
                size: 0
            )
        )
    )
}

private struct FakeImageClient: ClientImageProtocol, ImageSavingWithIdentity,
    ImageLoadingWithIdentity
{
    var images: [ClientImage] = []
    var loadedImages: [String] = []
    var loadedActorIDs: [String]?
    var failPushStream = false
    var saveDirectory: URL?
    var saveWritesTarball = true
    var savedActorIDs: [String]?

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { images }

    func delete(id: String) async throws -> ImageDeletionResult {
        ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil)
    }

    func pull(image: String, tag: String?, platform: Platform, fallbackPolicy: PlatformFallbackPolicy, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        let fail = failPushStream
        return AsyncThrowingStream { continuation in
            continuation.yield("Pushing \(reference)")
            if fail {
                continuation.finish(throwing: ClientImageError.notFound(id: reference))
            } else {
                continuation.finish()
            }
        }
    }

    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }

    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String],
        platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        (repo, "sha256:" + String(repeating: "a", count: 64))
    }

    func load(tarballPath: URL, platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] {
        loadedImages
    }

    func loadWithIdentities(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> LoadedImageArchive {
        let byReference = Dictionary(
            uniqueKeysWithValues: images.map { ($0.reference, $0.digest) }
        )
        return LoadedImageArchive(
            references: loadedImages,
            actorIDs: loadedActorIDs
                ?? loadedImages.map { byReference[$0] ?? $0 }
        )
    }

    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        let tempDir =
            saveDirectory
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tarball = tempDir.appendingPathComponent("images.tar")
        if saveWritesTarball {
            try Data("fake-saved-tarball".utf8).write(to: tarball)
        }
        return tarball
    }

    func saveWithIdentities(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> SavedImageArchive {
        let url = try await save(
            references: references,
            platform: platform,
            appleContainerAppSupportUrl: appleContainerAppSupportUrl,
            logger: logger
        )
        let byReference = Dictionary(
            uniqueKeysWithValues: images.map { ($0.reference, $0.digest) }
        )
        return SavedImageArchive(
            url: url,
            actorIDs: savedActorIDs
                ?? references.map { byReference[$0] ?? $0 }
        )
    }
}
