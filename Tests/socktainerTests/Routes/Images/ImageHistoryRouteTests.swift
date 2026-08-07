import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerResource
import ContainerizationOCI
import Testing
import Vapor

@testable import socktainer

private actor HistoryRunnableImageContentProvider:
    RunnableImageContentProviding
{
    let indexValue: Index
    let manifests: [String: Manifest]
    let configs: [String: ContainerizationOCI.Image]
    private var requestedConfigDigests: [String] = []

    init(
        index: Index,
        manifests: [String: Manifest],
        configs: [String: ContainerizationOCI.Image]
    ) {
        self.indexValue = index
        self.manifests = manifests
        self.configs = configs
    }

    func index(for image: ClientImage) async throws -> Index {
        indexValue
    }

    func manifest(digest: String) async throws -> Manifest? {
        manifests[digest]
    }

    func config(digest: String) async throws
        -> ContainerizationOCI.Image?
    {
        requestedConfigDigests.append(digest)
        return configs[digest]
    }

    func configRequests() -> [String] {
        requestedConfigDigests
    }
}

@Suite("Image history route")
struct ImageHistoryRouteTests {
    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private static func image(rootDigest: String) -> ClientImage {
        ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/history-selector:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: rootDigest,
                    size: 100
                )
            )
        )
    }

    private static func config(
        architecture: String,
        createdBy: String,
        comment: String
    ) -> ContainerizationOCI.Image {
        ContainerizationOCI.Image(
            created: "2026-08-07T12:00:00Z",
            architecture: architecture,
            os: "linux",
            rootfs: Rootfs(type: "layers", diffIDs: []),
            history: [
                History(
                    created: "2026-08-07T12:00:00Z",
                    createdBy: createdBy,
                    comment: comment
                )
            ]
        )
    }

    @Test(
        "artifact-first same-platform indexes use runnable config and layers"
    )
    func artifactFirstSamePlatformUsesRunnableHistory() async throws {
        let rootDigest = Self.digest("0")
        let artifactManifestDigest = Self.digest("1")
        let runnableManifestDigest = Self.digest("2")
        let artifactConfigDigest = Self.digest("3")
        let runnableConfigDigest = Self.digest("4")
        let artifactLayerDigest = Self.digest("5")
        let runnableLayerDigest = Self.digest("6")
        let platform = Platform(arch: "arm64", os: "linux")
        let runnableDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: runnableManifestDigest,
            size: 50,
            platform: platform
        )
        let artifactDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: artifactManifestDigest,
            size: 40,
            platform: platform
        )
        let provider = HistoryRunnableImageContentProvider(
            index: Index(
                manifests: [artifactDescriptor, runnableDescriptor]
            ),
            manifests: [
                artifactManifestDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: artifactConfigDigest,
                        size: 20
                    ),
                    layers: [
                        Descriptor(
                            mediaType: MediaTypes.imageLayer,
                            digest: artifactLayerDigest,
                            size: 41
                        )
                    ],
                    subject: runnableDescriptor
                ),
                runnableManifestDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: runnableConfigDigest,
                        size: 20
                    ),
                    layers: [
                        Descriptor(
                            mediaType: MediaTypes.imageLayer,
                            digest: runnableLayerDigest,
                            size: 61
                        )
                    ]
                ),
            ],
            configs: [
                artifactConfigDigest: Self.config(
                    architecture: "arm64",
                    createdBy: "ARTIFACT",
                    comment: "wrong history"
                ),
                runnableConfigDigest: Self.config(
                    architecture: "arm64",
                    createdBy: "RUNNABLE",
                    comment: "expected history"
                ),
            ]
        )
        let selector = RunnableImageSelector(contentProvider: provider)
        let image = Self.image(rootDigest: rootDigest)

        let items = try await ImageHistoryRoute.historyResponseItems(
            for: image,
            requestedName: image.reference,
            tags: [
                "docker.io/library/history-selector:latest",
                "docker.io/library/history-selector:stable",
            ],
            preferredPlatform: platform,
            runnableImageSelector: selector
        )

        #expect(items.count == 1)
        #expect(items[0].Id == runnableLayerDigest)
        #expect(items[0].Size == 61)
        #expect(items[0].CreatedBy == "RUNNABLE")
        #expect(items[0].Comment == "expected history")
        #expect(
            items[0].Tags == [
                "docker.io/library/history-selector:latest",
                "docker.io/library/history-selector:stable",
            ])
        #expect(await provider.configRequests() == [runnableConfigDigest])
    }

    @Test("an unavailable requested platform remains a Docker 404")
    func unavailableRequestedPlatformIsNotFound() async throws {
        let rootDigest = Self.digest("7")
        let manifestDigest = Self.digest("8")
        let configDigest = Self.digest("9")
        let available = Platform(arch: "arm64", os: "linux")
        let requested = Platform(arch: "amd64", os: "linux")
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 50,
            platform: available
        )
        let provider = HistoryRunnableImageContentProvider(
            index: Index(manifests: [descriptor]),
            manifests: [
                manifestDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: configDigest,
                        size: 20
                    ),
                    layers: []
                )
            ],
            configs: [
                configDigest: Self.config(
                    architecture: "arm64",
                    createdBy: "RUNNABLE",
                    comment: "available"
                )
            ]
        )
        let image = Self.image(rootDigest: rootDigest)

        do {
            _ = try await ImageHistoryRoute.historyResponseItems(
                for: image,
                requestedName: image.reference,
                tags: [],
                preferredPlatform: requested,
                runnableImageSelector: RunnableImageSelector(
                    contentProvider: provider
                )
            )
            Issue.record("Expected an unavailable platform to be rejected")
        } catch let error as Abort {
            #expect(error.status == .notFound)
            #expect(
                error.reason
                    == "Image '\(image.reference)' does not provide platform 'linux/amd64'"
            )
        }
    }

    @Test("an internal-only image root does not expose its physical reference as a tag")
    func internalOnlyRootHasNoHistoryTags() async throws {
        let rootDigest = Self.digest("a")
        let manifestDigest = Self.digest("b")
        let configDigest = Self.digest("c")
        let platform = Platform(arch: "arm64", os: "linux")
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 50,
            platform: platform
        )
        let provider = HistoryRunnableImageContentProvider(
            index: Index(manifests: [descriptor]),
            manifests: [
                manifestDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: configDigest,
                        size: 20
                    ),
                    layers: []
                )
            ],
            configs: [
                configDigest: Self.config(
                    architecture: "arm64",
                    createdBy: "RUNNABLE",
                    comment: "internal root"
                )
            ]
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: ContainerImageLease.reference(for: rootDigest),
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: rootDigest,
                    size: 100
                )
            )
        )

        let items = try await ImageHistoryRoute.historyResponseItems(
            for: image,
            requestedName: rootDigest,
            tags: [],
            preferredPlatform: platform,
            runnableImageSelector: RunnableImageSelector(
                contentProvider: provider
            )
        )

        #expect(items.count == 1)
        #expect(items[0].Tags.isEmpty)
    }
}
