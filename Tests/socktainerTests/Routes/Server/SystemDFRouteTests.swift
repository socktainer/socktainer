import ContainerAPIClient
import ContainerBuild
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct EmptyImageClient: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult { fatalError("not exercised by this test") }
    func pull(image: String, tag: String?, platform: Platform, fallbackPolicy: PlatformFallbackPolicy, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }
    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String], platform: Platform,
        appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) { fatalError("not exercised by this test") }
}

private struct EmptyVolumeClient: ClientVolumeProtocol {
    func create(request: RESTVolumeCreate) async throws -> Volume { fatalError("not exercised by this test") }
    func delete(name: String) async throws {}
    func list(filters: String?, logger: Logger) async throws -> [Volume] { [] }
    func inspect(name: String) async throws -> Volume { fatalError("not exercised by this test") }
}

private struct EmptyBuilderClient: ClientBuilderProtocol {
    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws {}
    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws
        -> any BuilderBuildSession
    {
        fatalError("not exercised when the default (includeAll) query builds an empty BuildCache")
    }
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        fatalError("not exercised by this test")
    }
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        fatalError("not exercised when the default (includeAll) query builds an empty BuildCache")
    }
}

private struct FixedDiskUsageProvider: ContainerDiskUsageProviding {
    func diskUsage(id: String) async throws -> UInt64 { 0 }
}

private struct FixedImageLayerDiskUsageProvider: ImageLayerDiskUsageProviding {
    func calculateDiskUsage(activeReferences: Set<String>) async throws -> (
        totalCount: Int, activeCount: Int, totalSize: UInt64, reclaimableSize: UInt64
    ) {
        (0, 0, 0, 0)
    }
}

private struct StaticImageStoreInventoryProvider: ImageStoreInventoryProviding {
    let inventory: ImageStoreInventory

    func imageStoreInventory(includeSystemImages: Bool) async throws -> ImageStoreInventory {
        inventory
    }
}

private struct FixedContainerImageMetadataProvider: ContainerImageMetadataProviding {
    let metadata: DockerContainerImageMetadata

    func metadata(for container: ContainerSnapshot) async -> DockerContainerImageMetadata {
        metadata
    }
}

private struct FixedDockerImageSummaryMetadataProvider:
    DockerImageSummaryMetadataProviding
{
    let configDigest: String

    func metadata(for image: ClientImage) async throws -> DockerImageSummaryMetadata {
        DockerImageSummaryMetadata(
            configDigest: configDigest,
            identityDigests: [image.digest, configDigest],
            created: 123,
            size: 456,
            labels: [:]
        )
    }
}

private actor RecordingImageLayerDiskUsageProvider: ImageLayerDiskUsageProviding {
    private var references: Set<String> = []

    func calculateDiskUsage(activeReferences: Set<String>) async throws -> (
        totalCount: Int, activeCount: Int, totalSize: UInt64,
        reclaimableSize: UInt64
    ) {
        references = activeReferences
        return (1, 1, 789, 0)
    }

    func capturedReferences() -> Set<String> {
        references
    }
}

private func imageIdentitySnapshot(
    id: String,
    reference: String,
    rootDigest: String
) -> ContainerSnapshot {
    let process = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    let image = ImageDescription(
        reference: reference,
        descriptor: Descriptor(
            mediaType: MediaTypes.index,
            digest: rootDigest,
            size: 0
        )
    )
    return ContainerSnapshot(
        configuration: ContainerConfiguration(
            id: id,
            image: image,
            process: process
        ),
        status: .running,
        networks: []
    )
}

private func clientImage(reference: String, rootDigest: String) -> ClientImage {
    ClientImage(
        description: ImageDescription(
            reference: reference,
            descriptor: Descriptor(
                mediaType: MediaTypes.index,
                digest: rootDigest,
                size: 0
            )
        )
    )
}

@Suite("SystemDFRoute — container network settings")
struct SystemDFRouteNetworkSettingsTests {

    private func withRoute(
        container: ContainerSnapshot,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            try app.register(
                collection: SystemDFRoute(
                    imageClient: EmptyImageClient(),
                    containerClient: StaticSnapshotClientMock(snapshot: container),
                    volumeClient: EmptyVolumeClient(),
                    builderClient: EmptyBuilderClient(),
                    diskUsageProvider: FixedDiskUsageProvider(),
                    imageLayerDiskUsageProvider: FixedImageLayerDiskUsageProvider()
                ))
            try await test(app)
        }
    }

    @Test("Duplicate live network names do not crash /system/df")
    func duplicateLiveNetworkNamesDoNotCrash() async throws {
        let container = try makeContainerSnapshot(
            nativeId: "c1",
            networks: [(network: "dup", ip: "192.168.64.5"), (network: "dup", ip: "192.168.64.5")],
            labels: [:],
            status: .running
        )
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/system/df") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(SystemDFResponse.self)
                #expect(body.Containers?.first?.NetworkSettings.Networks?.keys.contains("dup") == true)
            }
        }
    }

    @Test("Container Id is the canonical hex digest, matching /containers/json and /containers/{id}/json")
    func containerIdIsCanonicalHexDigest() async throws {
        let container = try makeContainerSnapshot(nativeId: "my-native-container", ip: "192.168.64.5", network: "mynet", labels: [:], status: .running)
        let expectedHexId = DockerContainerID.hexId(for: container)
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/system/df") { res async throws in
                let body = try res.content.decode(SystemDFResponse.self)
                #expect(body.Containers?.first?.Id == expectedHexId)
                #expect(
                    body.Containers?.first?.Id != "my-native-container",
                    "Id must not leak the raw native id — ContainerListRoute and ContainerInspectRoute both report the hex digest")
                #expect(body.Containers?.first?.Names == ["/my-native-container"], "Names, unlike Id, is the human-readable native id")
            }
        }
    }

    @Test("list, inspect, and system df share Docker config identity after a tag moves")
    func dockerImageIdentityIsConsistentAcrossContainerRoutes() async throws {
        let rootDigest = "sha256:" + String(repeating: "1", count: 64)
        let configDigest = "sha256:" + String(repeating: "2", count: 64)
        let originalReference = "docker.io/library/example:latest"
        let exactPhysicalReference = "example:latest"
        let container = imageIdentitySnapshot(
            id: "identity-container",
            reference: originalReference,
            rootDigest: rootDigest
        )
        let images = [
            clientImage(
                reference: "docker.io/library/example:first",
                rootDigest: rootDigest
            ),
            clientImage(
                reference: "docker.io/library/example:second",
                rootDigest: rootDigest
            ),
            clientImage(
                reference: "moby-dangling@\(rootDigest)",
                rootDigest: rootDigest
            ),
            clientImage(reference: rootDigest, rootDigest: rootDigest),
        ]
        let metadataProvider = FixedContainerImageMetadataProvider(
            metadata: DockerContainerImageMetadata(
                rootDigest: rootDigest,
                configDigest: configDigest,
                displayReference: configDigest
            )
        )
        let inventoryProvider = StaticImageStoreInventoryProvider(
            inventory: ImageStoreInventory(
                images: images,
                physicalReferencesByRootDigest: [
                    rootDigest: [exactPhysicalReference]
                ]
            )
        )
        let layerUsageProvider = RecordingImageLayerDiskUsageProvider()
        let containerClient = StaticSnapshotClientMock(snapshot: container)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            try app.register(
                collection: ContainerListRoute(
                    client: containerClient,
                    imageMetadataProvider: metadataProvider
                )
            )
            try app.register(
                collection: ContainerInspectRoute(
                    client: containerClient,
                    imageMetadataProvider: metadataProvider
                )
            )
            try app.register(
                collection: SystemDFRoute(
                    imageClient: EmptyImageClient(),
                    containerClient: containerClient,
                    volumeClient: EmptyVolumeClient(),
                    builderClient: EmptyBuilderClient(),
                    diskUsageProvider: FixedDiskUsageProvider(),
                    imageLayerDiskUsageProvider: layerUsageProvider,
                    imageInventoryProvider: inventoryProvider,
                    imageMetadataProvider: metadataProvider,
                    imageSummaryMetadataProvider:
                        FixedDockerImageSummaryMetadataProvider(
                            configDigest: configDigest
                        )
                )
            )

            try await app.testing().test(
                .GET,
                "/v1.51/containers/json?all=true"
            ) { response async throws in
                let summaries = try response.content.decode(
                    [RESTContainerSummary].self
                )
                #expect(summaries.first?.Image == configDigest)
                #expect(summaries.first?.ImageID == configDigest)
            }

            try await app.testing().test(
                .GET,
                "/v1.51/containers/identity-container/json"
            ) { response async throws in
                let inspect = try response.content.decode(
                    RESTContainerInspect.self
                )
                #expect(inspect.Image == configDigest)
                #expect(inspect.Config.Image == originalReference)
            }

            try await app.testing().test(.GET, "/v1.51/system/df") {
                response async throws in
                let systemDF = try response.content.decode(
                    SystemDFResponse.self
                )
                #expect(systemDF.Containers?.first?.Image == configDigest)
                #expect(systemDF.Containers?.first?.ImageID == configDigest)
                #expect(systemDF.Images?.count == 1)
                #expect(systemDF.Images?.first?.Id == configDigest)
                #expect(
                    systemDF.Images?.first?.RepoTags == [
                        "docker.io/library/example:first",
                        "docker.io/library/example:second",
                    ]
                )
                #expect(systemDF.Images?.first?.Containers == 1)
                #expect(systemDF.LayersSize == 789)
            }
        }

        #expect(
            await layerUsageProvider.capturedReferences()
                == [exactPhysicalReference]
        )
    }
}
