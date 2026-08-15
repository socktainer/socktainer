import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Logging
import Testing

@testable import GlassDock

@Suite("ClientImageService artifact-safe selection")
struct ClientImageServiceArtifactSelectionTests {
    enum FixtureError: Error, Equatable {
        case backendUnavailable
    }

    @Test("an unspecified push preserves the full graph when artifacts are attached")
    func pushPlatformPreservesArtifacts() async throws {
        let platform = Platform(arch: "arm64", os: "linux")
        let runnableDigest = Self.digest("2")
        let artifactDigest = Self.digest("3")
        let runnableConfigDigest = Self.digest("4")
        let artifactConfigDigest = Self.digest("5")
        let runnable = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: runnableDigest,
            size: 100,
            platform: platform
        )
        let artifact = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: artifactDigest,
            size: 80,
            platform: platform,
            artifactType: "application/vnd.example.provenance"
        )
        let provider = ServiceArtifactContentProvider(
            index: Index(manifests: [artifact, runnable]),
            manifests: [
                runnableDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: runnableConfigDigest,
                        size: 20
                    ),
                    layers: []
                ),
                artifactDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: artifactConfigDigest,
                        size: 20
                    ),
                    layers: [],
                    subject: runnable,
                    artifactType: "application/vnd.example.provenance"
                ),
            ],
            configs: [
                runnableConfigDigest: Self.config(architecture: "arm64"),
                artifactConfigDigest: Self.config(architecture: "unknown"),
            ]
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/example:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: Self.digest("1"),
                    size: 200
                )
            )
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            runnableImageSelector: RunnableImageSelector(
                contentProvider: provider
            )
        )

        let selected = try await service.resolvedPushPlatform(
            for: image,
            requestedPlatform: nil,
            logger: Logger(label: "artifact-safe-push-test")
        )

        #expect(selected == nil)
    }

    @Test("selector backend failures are not converted to missing content")
    func selectorPreservesBackendFailure() async throws {
        let image = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/example:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: Self.digest("8"),
                    size: 200
                )
            )
        )
        let selector = RunnableImageSelector(
            contentProvider: FailingServiceArtifactContentProvider()
        )

        await #expect(throws: FixtureError.backendUnavailable) {
            try await selector.descriptors(for: image)
        }
    }

    @Test("config-dependent prune filters never select a root without runnable config")
    func pruneRequiresRunnableConfig() {
        #expect(
            ClientImageService.pruneCandidateHasRequiredConfig(
                true,
                requiresConfig: true,
                hasRunnableConfig: false
            ) == false
        )
        #expect(
            ClientImageService.pruneCandidateHasRequiredConfig(
                true,
                requiresConfig: true,
                hasRunnableConfig: true
            )
        )
        #expect(
            ClientImageService.pruneCandidateHasRequiredConfig(
                true,
                requiresConfig: false,
                hasRunnableConfig: false
            )
        )
    }

    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private static func config(
        architecture: String
    ) -> ContainerizationOCI.Image {
        ContainerizationOCI.Image(
            architecture: architecture,
            os: architecture == "unknown" ? "unknown" : "linux",
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
    }
}

private struct FailingServiceArtifactContentProvider:
    RunnableImageContentProviding
{
    func index(for image: ClientImage) async throws -> Index {
        Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: "sha256:" + String(repeating: "9", count: 64),
                    size: 100,
                    platform: Platform(arch: "arm64", os: "linux")
                )
            ]
        )
    }

    func manifest(digest: String) async throws -> Manifest? {
        throw ClientImageServiceArtifactSelectionTests.FixtureError
            .backendUnavailable
    }

    func config(digest: String) async throws -> ContainerizationOCI.Image? {
        nil
    }
}

private struct ServiceArtifactContentProvider:
    RunnableImageContentProviding
{
    let index: Index
    let manifests: [String: Manifest]
    let configs: [String: ContainerizationOCI.Image]

    func index(for image: ClientImage) async throws -> Index {
        index
    }

    func manifest(digest: String) async throws -> Manifest? {
        manifests[digest]
    }

    func config(digest: String) async throws -> ContainerizationOCI.Image? {
        configs[digest]
    }
}
