import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private actor RecordingRunnableImageContentProvider:
    RunnableImageContentProviding
{
    enum FixtureError: Error {
        case missingIndex(String)
    }

    let indexes: [String: Index]
    let manifests: [String: Manifest]
    let configs: [String: ContainerizationOCI.Image]
    private var requestedIndexDigests: [String] = []
    private var requestedManifestDigests: [String] = []
    private var requestedConfigDigests: [String] = []

    init(
        indexes: [String: Index],
        manifests: [String: Manifest],
        configs: [String: ContainerizationOCI.Image]
    ) {
        self.indexes = indexes
        self.manifests = manifests
        self.configs = configs
    }

    func index(for image: ClientImage) async throws -> Index {
        guard let index = indexes[image.digest] else {
            throw FixtureError.missingIndex(image.digest)
        }
        return index
    }

    func index(digest: String) async throws -> Index? {
        requestedIndexDigests.append(digest)
        return indexes[digest]
    }

    func manifest(digest: String) async throws -> Manifest? {
        requestedManifestDigests.append(digest)
        return manifests[digest]
    }

    func config(digest: String) async throws
        -> ContainerizationOCI.Image?
    {
        requestedConfigDigests.append(digest)
        return configs[digest]
    }

    func contentRequests() -> (
        indexes: [String], manifests: [String], configs: [String]
    ) {
        (
            requestedIndexDigests,
            requestedManifestDigests,
            requestedConfigDigests
        )
    }
}

private actor RecordingRunnableSnapshotProvider:
    RunnableImageSnapshotProviding
{
    let filesystem: Filesystem
    private(set) var selectedDigest: String?
    private(set) var requiredExactSnapshot = false

    init(filesystem: Filesystem) {
        self.filesystem = filesystem
    }

    func snapshot(
        for image: ClientImage,
        variant: RunnableImageVariant,
        descriptors: [ResolvedImageDescriptor],
        logger: Logger
    ) async throws -> RunnableImageSnapshot {
        selectedDigest = variant.descriptor.digest
        requiredExactSnapshot =
            LiveRunnableImageSnapshotProvider.requiresExactSnapshot(
                variant: variant,
                descriptors: descriptors
            )
        return RunnableImageSnapshot(filesystem: filesystem)
    }
}

private struct StaticRunnableImageClient: ClientImageProtocol {
    let image: ClientImage

    func list(includeSystemImages: Bool) async throws -> [ClientImage] {
        [image]
    }

    func delete(id: String) async throws -> ImageDeletionResult {
        fatalError("not exercised")
    }

    func pull(
        image: String,
        tag: String?,
        platform: Platform,
        fallbackPolicy: PlatformFallbackPolicy,
        logger: Logger
    ) async throws -> AsyncThrowingStream<PullProgress, Error> {
        fatalError("not exercised")
    }

    func push(
        reference: String,
        platform: Platform?,
        logger: Logger
    ) async throws -> AsyncThrowingStream<String, Error> {
        fatalError("not exercised")
    }

    func prune(
        filters: [String: [String]],
        logger: Logger
    ) async throws -> (
        results: [ImageDeletionResult], spaceReclaimed: Int64
    ) {
        fatalError("not exercised")
    }

    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> [String] {
        fatalError("not exercised")
    }

    func save(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> URL {
        fatalError("not exercised")
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
        fatalError("not exercised")
    }
}

private struct StaticSelectorIdentityCatalog: ImageIdentityCatalog {
    let image: ClientImage
    let indexValue: Index
    let nestedIndexes: [String: Index]
    let manifests: [String: Manifest]

    init(
        image: ClientImage,
        indexValue: Index,
        nestedIndexes: [String: Index] = [:],
        manifests: [String: Manifest]
    ) {
        self.image = image
        self.indexValue = indexValue
        self.nestedIndexes = nestedIndexes
        self.manifests = manifests
    }

    func list() async throws -> [ClientImage] {
        [image]
    }

    func index(for image: ClientImage) async throws -> Index {
        indexValue
    }

    func index(digest: String) async throws -> Index? {
        nestedIndexes[digest]
    }

    func manifest(digest: String) async throws -> Manifest? {
        manifests[digest]
    }
}

@Suite("Runnable OCI image selection")
struct RunnableImageSelectorTests {
    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private static func numberedDigest(_ value: Int) -> String {
        "sha256:" + String(format: "%064x", value)
    }

    private static func clientImage(rootDigest: String) -> ClientImage {
        ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/selector:latest",
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
        os: String = "linux",
        label: String
    ) -> ContainerizationOCI.Image {
        ContainerizationOCI.Image(
            created: "2026-08-07T12:00:00Z",
            architecture: architecture,
            os: os,
            config: ImageConfig(labels: ["fixture": label]),
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
    }

    private static func manifest(
        configDigest: String,
        artifactType: String? = nil,
        subject: Descriptor? = nil,
        annotations: [String: String]? = nil
    ) -> Manifest {
        Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configDigest,
                size: 20
            ),
            layers: [],
            annotations: annotations,
            subject: subject,
            artifactType: artifactType
        )
    }

    private static func amd64OnlySelectionFixture() -> (
        image: ClientImage,
        selector: RunnableImageSelector,
        snapshotProvider: RecordingRunnableSnapshotProvider,
        manifestDigest: String
    ) {
        let rootDigest = numberedDigest(90_000)
        let manifestDigest = numberedDigest(90_001)
        let configDigest = numberedDigest(90_002)
        let amd64 = Platform(arch: "amd64", os: "linux")
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 100,
            platform: amd64
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [rootDigest: Index(manifests: [descriptor])],
            manifests: [
                manifestDigest: manifest(configDigest: configDigest)
            ],
            configs: [
                configDigest: config(
                    architecture: "amd64",
                    label: "amd64-only"
                )
            ]
        )
        let snapshotProvider = RecordingRunnableSnapshotProvider(
            filesystem: .block(
                format: "ext4",
                source: "/tmp/socktainer-platform-policy-unused.ext4",
                destination: "/",
                options: []
            )
        )
        return (
            clientImage(rootDigest: rootDigest),
            RunnableImageSelector(contentProvider: provider),
            snapshotProvider,
            manifestDigest
        )
    }

    @Test("strict arm64 selection never falls back to an amd64 image")
    func strictSelectionDoesNotFallbackToAMD64() async throws {
        let fixture = Self.amd64OnlySelectionFixture()

        do {
            _ = try await ContainerCreateRoute.prepareRunnableImage(
                image: fixture.image,
                requestedPlatform: Platform(arch: "arm64", os: "linux"),
                fallbackPolicy: .strict,
                selector: fixture.selector,
                snapshotProvider: fixture.snapshotProvider,
                logger: Logger(label: "strict-platform-test")
            )
            Issue.record("expected strict arm64 selection to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .unsupported)
        }
        #expect(await fixture.snapshotProvider.selectedDigest == nil)
    }

    @Test("implicit host-default arm64 selection may fall back to amd64")
    func implicitSelectionMayFallbackToAMD64() async throws {
        let fixture = Self.amd64OnlySelectionFixture()

        let prepared = try await ContainerCreateRoute.prepareRunnableImage(
            image: fixture.image,
            requestedPlatform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .allowRosetta,
            selector: fixture.selector,
            snapshotProvider: fixture.snapshotProvider,
            logger: Logger(label: "implicit-platform-test")
        )

        #expect(prepared.variant.platform.architecture == "amd64")
        #expect(prepared.variant.descriptor.digest == fixture.manifestDigest)
        #expect(
            await fixture.snapshotProvider.selectedDigest
                == fixture.manifestDigest
        )
    }

    private static func snapshot(
        image: ClientImage,
        platform: Platform
    ) -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        var configuration = ContainerConfiguration(
            id: "selector-container",
            image: image.description,
            process: process
        )
        configuration.platform = platform
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: []
        )
    }

    @Test("artifact-first same-platform content cannot supply Docker config identity")
    func artifactFirstSamePlatformUsesRunnableDigest() async throws {
        let rootDigest = Self.digest("0")
        let artifactManifestDigest = Self.digest("1")
        let runnableManifestDigest = Self.digest("2")
        let artifactConfigDigest = Self.digest("3")
        let runnableConfigDigest = Self.digest("4")
        let platform = Platform(arch: "arm64", os: "linux")
        let subject = Descriptor(
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
        let runnableDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: runnableManifestDigest,
            size: 50,
            platform: platform
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [
                rootDigest: Index(
                    manifests: [artifactDescriptor, runnableDescriptor]
                )
            ],
            manifests: [
                artifactManifestDigest: Self.manifest(
                    configDigest: artifactConfigDigest,
                    subject: subject
                ),
                runnableManifestDigest: Self.manifest(
                    configDigest: runnableConfigDigest
                ),
            ],
            configs: [
                artifactConfigDigest: Self.config(
                    architecture: "arm64",
                    label: "artifact"
                ),
                runnableConfigDigest: Self.config(
                    architecture: "arm64",
                    label: "runnable"
                ),
            ]
        )
        let selector = RunnableImageSelector(contentProvider: provider)
        let image = Self.clientImage(rootDigest: rootDigest)
        let descriptors = try await selector.descriptors(for: image)

        #expect(descriptors.map(\.kind) == [.artifact, .image])
        #expect(descriptors[0].runnableVariant == nil)
        #expect(
            selector.selectVariant(
                from: descriptors,
                requestedPlatform: platform,
                hostPlatform: platform
            )?.manifest.config.digest == runnableConfigDigest
        )
        #expect(
            await ContainerImageIdentity.configDigest(
                for: image,
                runnableImageSelector: selector
            ) == runnableConfigDigest
        )
        #expect(
            await ContainerImageIdentity.configDigest(
                for: Self.snapshot(image: image, platform: platform),
                runnableImageSelector: selector
            ) == runnableConfigDigest
        )
        let systemDFMetadata = try await LiveDockerImageSummaryMetadataProvider(
            runnableImageSelector: selector
        ).metadata(for: image)
        #expect(systemDFMetadata.configDigest == runnableConfigDigest)
        #expect(systemDFMetadata.labels["fixture"] == "runnable")
        #expect(
            systemDFMetadata.identityDigests == [
                rootDigest,
                runnableManifestDigest,
            ]
        )

        let requests = await provider.contentRequests()
        #expect(
            Set(requests.manifests)
                == [artifactManifestDigest, runnableManifestDigest]
        )
        #expect(
            Set(requests.configs) == [runnableConfigDigest],
            "artifact config content must never be loaded as runnable metadata"
        )
    }

    @Test("image list and inspect both emit the runnable config from an artifact-first index")
    func imageRoutesUseRunnableConfigIdentity() async throws {
        let rootDigest = Self.digest("9")
        let artifactManifestDigest = Self.digest("a")
        let runnableManifestDigest = Self.digest("b")
        let artifactConfigDigest = Self.digest("c")
        let runnableConfigDigest = Self.digest("d")
        let platform = Platform.current
        let documentArtifactAnnotations = [
            OCIArtifactSemantics.buildKitReferenceTypeAnnotation:
                OCIArtifactSemantics.buildKitAttestationManifest,
            OCIArtifactSemantics.buildKitReferenceDigestAnnotation:
                runnableManifestDigest,
        ]
        let artifactDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: artifactManifestDigest,
            size: 40,
            platform: platform
        )
        let runnableDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: runnableManifestDigest,
            size: 50,
            platform: platform
        )
        let index = Index(
            manifests: [artifactDescriptor, runnableDescriptor]
        )
        let manifests = [
            artifactManifestDigest: Self.manifest(
                configDigest: artifactConfigDigest,
                annotations: documentArtifactAnnotations
            ),
            runnableManifestDigest: Self.manifest(
                configDigest: runnableConfigDigest
            ),
        ]
        let provider = RecordingRunnableImageContentProvider(
            indexes: [rootDigest: index],
            manifests: manifests,
            configs: [
                artifactConfigDigest: Self.config(
                    architecture: platform.architecture,
                    label: "artifact"
                ),
                runnableConfigDigest: Self.config(
                    architecture: platform.architecture,
                    label: "runnable"
                ),
            ]
        )
        let selector = RunnableImageSelector(contentProvider: provider)
        let image = Self.clientImage(rootDigest: rootDigest)
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticSelectorIdentityCatalog(
                image: image,
                indexValue: index,
                manifests: manifests
            ),
            appSupportURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )

        try await withApp { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] =
                FileManager.default.temporaryDirectory

            try app.register(
                collection: ImageListRoute(
                    client: StaticRunnableImageClient(image: image),
                    runnableImageSelector: selector,
                    containerListProvider: { [] }
                )
            )
            try app.register(
                collection: ImageInspectRoute(
                    systemConfig: ContainerSystemConfig(),
                    identityResolver: resolver,
                    runnableImageSelector: selector
                )
            )

            try await app.testing().test(
                .GET,
                "/v1.51/images/json?manifests=true&digests=true"
            ) { response async throws in
                #expect(response.status == .ok)
                let summaries = try response.content.decode(
                    [RESTImageSummary].self
                )
                let summary = try #require(summaries.first)
                #expect(summary.Id == runnableConfigDigest)
                #expect(summary.Labels["fixture"] == "runnable")
                #expect(summary.Manifests?.map(\.Kind) == ["image", "attestation"])
                #expect(
                    summary.Manifests?.last?.AttestationData?.For
                        == runnableManifestDigest
                )
            }

            try await app.testing().test(
                .GET,
                "/v1.51/images/docker.io/library/selector:latest/json?manifests=true"
            ) { response async throws in
                #expect(response.status == .ok)
                let inspect = try response.content.decode(
                    RESTImageInspect.self
                )
                #expect(inspect.Id == runnableConfigDigest)
                #expect(inspect.Config?.Labels?["fixture"] == "runnable")
                #expect(inspect.Architecture == platform.architecture)
                #expect(inspect.Manifests?.map(\.Kind) == ["image", "attestation"])
                #expect(
                    inspect.Manifests?.first(where: {
                        $0.Kind == "attestation"
                    })?.AttestationData?.For == runnableManifestDigest
                )
            }
        }

        #expect(
            !Set(await provider.contentRequests().configs).contains(
                artifactConfigDigest
            )
        )
    }

    @Test("every OCI and BuildKit artifact marker plus unknown platforms is excluded")
    func allArtifactMarkersAreExcluded() async throws {
        let rootDigest = Self.digest("5")
        let platform = Platform(arch: "arm64", os: "linux")
        let subject = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: Self.digest("6"),
            size: 1
        )
        let buildKitAnnotation = [
            OCIArtifactSemantics.buildKitReferenceTypeAnnotation:
                OCIArtifactSemantics.buildKitAttestationManifest
        ]

        let descriptors = [
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("a"),
                size: 1,
                platform: platform,
                artifactType: "application/vnd.example.artifact"
            ),
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("b"),
                size: 1,
                annotations: buildKitAnnotation,
                platform: platform
            ),
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("c"),
                size: 1,
                platform: platform
            ),
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("d"),
                size: 1,
                platform: platform
            ),
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("e"),
                size: 1,
                platform: platform
            ),
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("f"),
                size: 1,
                platform: nil
            ),
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("7"),
                size: 1,
                platform: Platform(arch: "unknown", os: "unknown")
            ),
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: Self.digest("8"),
                size: 1,
                platform: platform
            ),
        ]
        let configDigests = Dictionary(
            uniqueKeysWithValues: descriptors.enumerated().map {
                ($1.digest, Self.digest(Character(String($0))))
            }
        )
        let manifests: [String: Manifest] = [
            descriptors[0].digest: Self.manifest(
                configDigest: configDigests[descriptors[0].digest]!
            ),
            descriptors[1].digest: Self.manifest(
                configDigest: configDigests[descriptors[1].digest]!
            ),
            descriptors[2].digest: Self.manifest(
                configDigest: configDigests[descriptors[2].digest]!,
                artifactType: "application/vnd.example.artifact"
            ),
            descriptors[3].digest: Self.manifest(
                configDigest: configDigests[descriptors[3].digest]!,
                subject: subject
            ),
            descriptors[4].digest: Self.manifest(
                configDigest: configDigests[descriptors[4].digest]!,
                annotations: buildKitAnnotation
            ),
            descriptors[5].digest: Self.manifest(
                configDigest: configDigests[descriptors[5].digest]!
            ),
            descriptors[6].digest: Self.manifest(
                configDigest: configDigests[descriptors[6].digest]!
            ),
            descriptors[7].digest: Self.manifest(
                configDigest: configDigests[descriptors[7].digest]!
            ),
        ]
        let configs = Dictionary(
            uniqueKeysWithValues: configDigests.values.map {
                ($0, Self.config(architecture: "arm64", label: $0))
            }
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [rootDigest: Index(manifests: descriptors)],
            manifests: manifests,
            configs: configs
        )
        let selector = RunnableImageSelector(contentProvider: provider)
        let resolved = try await selector.descriptors(
            for: Self.clientImage(rootDigest: rootDigest)
        )

        #expect(resolved.compactMap(\.runnableVariant).count == 1)
        #expect(
            resolved.compactMap(\.runnableVariant).first?.descriptor.digest
                == descriptors[7].digest
        )
        #expect(
            Set(await provider.contentRequests().configs)
                == [configDigests[descriptors[7].digest]!]
        )
    }

    @Test("nested multi-platform indexes select immutable leaves and force exact snapshots")
    func nestedMultiPlatformIndex() async throws {
        let rootDigest = Self.numberedDigest(100)
        let nestedIndexDigest = Self.numberedDigest(101)
        let armManifestDigest = Self.numberedDigest(102)
        let amdManifestDigest = Self.numberedDigest(103)
        let armConfigDigest = Self.numberedDigest(104)
        let amdConfigDigest = Self.numberedDigest(105)
        let arm = Platform(arch: "arm64", os: "linux")
        let amd = Platform(arch: "amd64", os: "linux")
        let nestedDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: nestedIndexDigest,
            size: 80
        )
        let armDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: armManifestDigest,
            size: 40,
            platform: arm
        )
        let amdDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: amdManifestDigest,
            size: 40,
            platform: amd
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [
                rootDigest: Index(manifests: [nestedDescriptor]),
                nestedIndexDigest: Index(
                    manifests: [amdDescriptor, armDescriptor]
                ),
            ],
            manifests: [
                armManifestDigest: Self.manifest(
                    configDigest: armConfigDigest
                ),
                amdManifestDigest: Self.manifest(
                    configDigest: amdConfigDigest
                ),
            ],
            configs: [
                armConfigDigest: Self.config(
                    architecture: "arm64",
                    label: "nested-arm"
                ),
                amdConfigDigest: Self.config(
                    architecture: "amd64",
                    label: "nested-amd"
                ),
            ]
        )
        let selector = RunnableImageSelector(contentProvider: provider)
        let descriptors = try await selector.descriptors(
            for: Self.clientImage(rootDigest: rootDigest)
        )

        #expect(descriptors.count == 2)
        #expect(Set(descriptors.map(\.pathDepth)) == [2])
        #expect(
            descriptors.allSatisfy {
                $0.runnableAncestorIndexDigests == [nestedIndexDigest]
            }
        )
        let selected = try #require(
            selector.selectVariant(
                from: descriptors,
                requestedPlatform: arm,
                hostPlatform: arm
            )
        )
        #expect(selected.descriptor.digest == armManifestDigest)
        #expect(selected.pathDepth == 2)
        #expect(
            LiveRunnableImageSnapshotProvider.requiresExactSnapshot(
                variant: selected,
                descriptors: descriptors
            )
        )
        #expect(
            RunnableImageSelector.dockerIdentityDigests(
                rootDigest: rootDigest,
                descriptors: descriptors
            ) == [
                rootDigest,
                nestedIndexDigest,
                armManifestDigest,
                amdManifestDigest,
            ]
        )
        #expect(await provider.contentRequests().indexes == [nestedIndexDigest])

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let rootfs = temporaryDirectory.appendingPathComponent("rootfs.ext4")
        try Data(repeating: 0, count: 4_096).write(to: rootfs)
        let snapshotProvider = RecordingRunnableSnapshotProvider(
            filesystem: .block(
                format: "ext4",
                source: rootfs.path,
                destination: "/",
                options: []
            )
        )
        let prepared = try await ContainerCreateRoute.prepareRunnableImage(
            image: Self.clientImage(rootDigest: rootDigest),
            requestedPlatform: arm,
            fallbackPolicy: .strict,
            selector: selector,
            snapshotProvider: snapshotProvider,
            logger: Logger(label: "nested-create-test")
        )
        #expect(prepared.variant.descriptor.digest == armManifestDigest)
        #expect(await snapshotProvider.selectedDigest == armManifestDigest)
        #expect(await snapshotProvider.requiredExactSnapshot)

        let image = Self.clientImage(rootDigest: rootDigest)
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticSelectorIdentityCatalog(
                image: image,
                indexValue: Index(manifests: [nestedDescriptor]),
                nestedIndexes: [
                    nestedIndexDigest: Index(
                        manifests: [amdDescriptor, armDescriptor]
                    )
                ],
                manifests: [
                    armManifestDigest: Self.manifest(
                        configDigest: armConfigDigest
                    ),
                    amdManifestDigest: Self.manifest(
                        configDigest: amdConfigDigest
                    ),
                ]
            ),
            appSupportURL: temporaryDirectory
        )
        try await withApp { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] =
                temporaryDirectory
            try app.register(
                collection: ImageInspectRoute(
                    systemConfig: ContainerSystemConfig(),
                    identityResolver: resolver,
                    runnableImageSelector: selector
                )
            )

            try await app.testing().test(
                .GET,
                "/v1.51/images/\(nestedIndexDigest)/json?manifests=true"
            ) { response async throws in
                #expect(response.status == .ok)
                let inspect = try response.content.decode(
                    RESTImageInspect.self
                )
                #expect(inspect.Id == armConfigDigest)
                #expect(inspect.Architecture == "arm64")
                #expect(
                    Set(inspect.Manifests?.map(\.ID) ?? [])
                        == [armManifestDigest, amdManifestDigest]
                )
            }
        }
    }

    @Test("artifact indexes are terminal and report document-level subjects")
    func artifactIndexIsTerminal() async throws {
        let rootDigest = Self.numberedDigest(110)
        let artifactIndexDigest = Self.numberedDigest(111)
        let hiddenManifestDigest = Self.numberedDigest(112)
        let hiddenConfigDigest = Self.numberedDigest(113)
        let subjectDigest = Self.numberedDigest(114)
        let platform = Platform(arch: "arm64", os: "linux")
        let artifactIndexDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: artifactIndexDigest,
            size: 80,
            platform: platform
        )
        let hiddenManifestDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: hiddenManifestDigest,
            size: 40,
            platform: platform
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [
                rootDigest: Index(manifests: [artifactIndexDescriptor]),
                artifactIndexDigest: Index(
                    manifests: [hiddenManifestDescriptor],
                    subject: Descriptor(
                        mediaType: MediaTypes.imageManifest,
                        digest: subjectDigest,
                        size: 40,
                        platform: platform
                    )
                ),
            ],
            manifests: [
                hiddenManifestDigest: Self.manifest(
                    configDigest: hiddenConfigDigest
                )
            ],
            configs: [
                hiddenConfigDigest: Self.config(
                    architecture: "arm64",
                    label: "must-not-load"
                )
            ]
        )
        let selector = RunnableImageSelector(contentProvider: provider)
        let descriptors = try await selector.descriptors(
            for: Self.clientImage(rootDigest: rootDigest)
        )
        let artifact = try #require(descriptors.first)

        #expect(descriptors.count == 1)
        #expect(artifact.kind == .artifact)
        #expect(artifact.documentAvailable)
        #expect(artifact.artifactSubjectDigest == subjectDigest)
        #expect(artifact.runnableVariant == nil)
        #expect(!ImageListRoute.isDockerImageRoot(descriptors))
        let requests = await provider.contentRequests()
        #expect(requests.indexes == [artifactIndexDigest])
        #expect(requests.manifests.isEmpty)
        #expect(requests.configs.isEmpty)
    }

    @Test(
        "manifest, config, and nested-index IDs preserve exact same-platform selection"
    )
    func immutableIdentityConstrainsSamePlatformSelection() async throws {
        let rootDigest = Self.numberedDigest(200)
        let firstIndexDigest = Self.numberedDigest(201)
        let secondIndexDigest = Self.numberedDigest(202)
        let firstManifestDigest = Self.numberedDigest(203)
        let secondManifestDigest = Self.numberedDigest(204)
        let firstConfigDigest = Self.numberedDigest(205)
        let secondConfigDigest = Self.numberedDigest(206)
        let platform = Platform(arch: "arm64", os: "linux")
        let firstIndexDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: firstIndexDigest,
            size: 60
        )
        let secondIndexDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: secondIndexDigest,
            size: 60
        )
        let firstManifestDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: firstManifestDigest,
            size: 40,
            platform: platform
        )
        let secondManifestDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: secondManifestDigest,
            size: 40,
            platform: platform
        )
        let rootIndex = Index(
            manifests: [firstIndexDescriptor, secondIndexDescriptor]
        )
        let nestedIndexes = [
            firstIndexDigest: Index(manifests: [firstManifestDescriptor]),
            secondIndexDigest: Index(manifests: [secondManifestDescriptor]),
        ]
        let manifests = [
            firstManifestDigest: Self.manifest(
                configDigest: firstConfigDigest
            ),
            secondManifestDigest: Self.manifest(
                configDigest: secondConfigDigest
            ),
        ]
        let configs = [
            firstConfigDigest: Self.config(
                architecture: "arm64",
                label: "first"
            ),
            secondConfigDigest: Self.config(
                architecture: "arm64",
                label: "second"
            ),
        ]
        let image = Self.clientImage(rootDigest: rootDigest)
        let provider = RecordingRunnableImageContentProvider(
            indexes: [rootDigest: rootIndex].merging(nestedIndexes) {
                current, _ in current
            },
            manifests: manifests,
            configs: configs
        )
        let selector = RunnableImageSelector(contentProvider: provider)
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticSelectorIdentityCatalog(
                image: image,
                indexValue: rootIndex,
                nestedIndexes: nestedIndexes,
                manifests: manifests
            )
        )
        let descriptors = try await selector.descriptors(for: image)
        let manifestIdentity = try await resolver.resolve(
            secondManifestDigest
        )
        let configIdentity = try await resolver.resolve(secondConfigDigest)
        let nestedIdentity = try await resolver.resolve(secondIndexDigest)

        #expect(
            manifestIdentity.variantConstraint
                == .exactManifest(
                    manifestDigest: secondManifestDigest,
                    configDigest: secondConfigDigest
                )
        )
        #expect(configIdentity.variantConstraint == manifestIdentity.variantConstraint)
        #expect(
            nestedIdentity.variantConstraint
                == .descendantOfIndex(secondIndexDigest)
        )
        #expect(
            selector.selectVariant(
                from: descriptors,
                requestedPlatform: platform,
                identityConstraint: manifestIdentity.variantConstraint,
                hostPlatform: platform
            )?.descriptor.digest == secondManifestDigest
        )
        #expect(
            selector.selectVariant(
                from: descriptors,
                requestedPlatform: platform,
                identityConstraint: nestedIdentity.variantConstraint,
                hostPlatform: platform
            )?.descriptor.digest == secondManifestDigest
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let rootfs = temporaryDirectory.appendingPathComponent("rootfs.ext4")
        try Data(repeating: 0, count: 4_096).write(to: rootfs)
        let snapshotProvider = RecordingRunnableSnapshotProvider(
            filesystem: .block(
                format: "ext4",
                source: rootfs.path,
                destination: "/",
                options: []
            )
        )
        let prepared = try await ContainerCreateRoute.prepareRunnableImage(
            image: image,
            requestedPlatform: platform,
            fallbackPolicy: .strict,
            identityConstraint: configIdentity.variantConstraint,
            selector: selector,
            snapshotProvider: snapshotProvider,
            logger: Logger(label: "exact-identity-create-test")
        )
        #expect(prepared.variant.descriptor.digest == secondManifestDigest)
        #expect(await snapshotProvider.selectedDigest == secondManifestDigest)

        try await withApp { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] =
                temporaryDirectory
            try app.register(
                collection: ImageInspectRoute(
                    systemConfig: ContainerSystemConfig(),
                    identityResolver: resolver,
                    runnableImageSelector: selector
                )
            )

            for identifier in [
                secondManifestDigest, secondConfigDigest,
                secondIndexDigest,
            ] {
                try await app.testing().test(
                    .GET,
                    "/v1.51/images/\(identifier)/json"
                ) { response async throws in
                    #expect(response.status == .ok)
                    let inspect = try response.content.decode(
                        RESTImageInspect.self
                    )
                    #expect(inspect.Id == secondConfigDigest)
                    #expect(inspect.Config?.Labels?["fixture"] == "second")
                }
            }
        }
    }

    @Test("shared nested index DAGs are memoized by immutable descriptor semantics")
    func sharedNestedIndexIsMemoized() async throws {
        let rootDigest = Self.numberedDigest(120)
        let parentOneDigest = Self.numberedDigest(121)
        let parentTwoDigest = Self.numberedDigest(122)
        let sharedDigest = Self.numberedDigest(123)
        let manifestDigest = Self.numberedDigest(124)
        let configDigest = Self.numberedDigest(125)
        let platform = Platform(arch: "arm64", os: "linux")
        let sharedDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: sharedDigest,
            size: 60
        )
        let manifestDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 40,
            platform: platform
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [
                rootDigest: Index(
                    manifests: [
                        Descriptor(
                            mediaType: MediaTypes.index,
                            digest: parentOneDigest,
                            size: 70
                        ),
                        Descriptor(
                            mediaType: MediaTypes.index,
                            digest: parentTwoDigest,
                            size: 70
                        ),
                    ]
                ),
                parentOneDigest: Index(manifests: [sharedDescriptor]),
                parentTwoDigest: Index(manifests: [sharedDescriptor]),
                sharedDigest: Index(manifests: [manifestDescriptor]),
            ],
            manifests: [
                manifestDigest: Self.manifest(configDigest: configDigest)
            ],
            configs: [
                configDigest: Self.config(
                    architecture: "arm64",
                    label: "shared"
                )
            ]
        )
        let descriptors = try await RunnableImageSelector(
            contentProvider: provider
        ).descriptors(for: Self.clientImage(rootDigest: rootDigest))

        #expect(descriptors.count == 2)
        #expect(descriptors.allSatisfy { $0.pathDepth == 3 })
        let requests = await provider.contentRequests()
        #expect(requests.indexes.filter { $0 == sharedDigest }.count == 1)
        #expect(requests.manifests == [manifestDigest])
        #expect(requests.configs == [configDigest])
    }

    @Test("a broad OCI index is rejected before unbounded graph expansion")
    func broadGraphIsBounded() async throws {
        let platform = Platform(arch: "arm64", os: "linux")
        let root = Index(
            manifests: (0...10_000).map { offset in
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: Self.numberedDigest(20_000 + offset),
                    size: 1,
                    platform: platform
                )
            }
        )

        await #expect(throws: OCIImageGraphError.graphTooLarge) {
            try await OCIImageGraphWalker.walk(
                rootIndex: root,
                loadIndex: { _ in nil },
                loadManifest: { _ in nil }
            )
        }
    }

    @Test("cached repeated-child DAGs cannot expand output exponentially")
    func repeatedChildGraphIsBounded() async throws {
        let platform = Platform(arch: "arm64", os: "linux")
        let indexDigests = (0..<15).map {
            Self.numberedDigest(31_000 + $0)
        }
        let manifestDigest = Self.numberedDigest(32_000)
        let configDigest = Self.numberedDigest(32_001)
        let leaf = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 1,
            platform: platform
        )
        var indexes: [String: Index] = [:]
        for offset in indexDigests.indices {
            let child =
                offset == indexDigests.index(before: indexDigests.endIndex)
                ? leaf
                : Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigests[offset + 1],
                    size: 1
                )
            indexes[indexDigests[offset]] = Index(
                manifests: [child, child]
            )
        }
        let root = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigests[0],
                    size: 1
                )
            ]
        )
        let builtIndexes = indexes

        await #expect(throws: OCIImageGraphError.graphTooLarge) {
            try await OCIImageGraphWalker.walk(
                rootIndex: root,
                loadIndex: { builtIndexes[$0] },
                loadManifest: { digest in
                    guard digest == manifestDigest else { return nil }
                    return Self.manifest(configDigest: configDigest)
                }
            )
        }
    }

    @Test("cycles are cut without hiding an acyclic runnable sibling")
    func cycleWithRunnableSibling() async throws {
        let rootDigest = Self.numberedDigest(130)
        let cycleDigest = Self.numberedDigest(131)
        let manifestDigest = Self.numberedDigest(132)
        let configDigest = Self.numberedDigest(133)
        let platform = Platform(arch: "arm64", os: "linux")
        let cycleDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: cycleDigest,
            size: 60
        )
        let manifestDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 40,
            platform: platform
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [
                rootDigest: Index(manifests: [cycleDescriptor]),
                cycleDigest: Index(
                    manifests: [cycleDescriptor, manifestDescriptor]
                ),
            ],
            manifests: [
                manifestDigest: Self.manifest(configDigest: configDigest)
            ],
            configs: [
                configDigest: Self.config(
                    architecture: "arm64",
                    label: "cycle-sibling"
                )
            ]
        )
        let descriptors = try await RunnableImageSelector(
            contentProvider: provider
        ).descriptors(for: Self.clientImage(rootDigest: rootDigest))

        #expect(descriptors.count == 1)
        #expect(descriptors.first?.runnableVariant != nil)
        #expect(
            descriptors.first?.runnableAncestorIndexDigests
                == [cycleDigest]
        )
    }

    @Test("descriptor metadata is occurrence-specific even for one content digest")
    func sharedDigestKeepsDescriptorSemantics() async throws {
        let rootDigest = Self.numberedDigest(140)
        let manifestDigest = Self.numberedDigest(141)
        let configDigest = Self.numberedDigest(142)
        let subjectDigest = Self.numberedDigest(143)
        let platform = Platform(arch: "arm64", os: "linux")
        let artifactDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 40,
            annotations: [
                OCIArtifactSemantics.buildKitReferenceTypeAnnotation:
                    OCIArtifactSemantics.buildKitAttestationManifest,
                OCIArtifactSemantics.buildKitReferenceDigestAnnotation:
                    subjectDigest,
            ],
            platform: platform
        )
        let runnableDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest,
            size: 40,
            platform: platform
        )
        let provider = RecordingRunnableImageContentProvider(
            indexes: [
                rootDigest: Index(
                    manifests: [artifactDescriptor, runnableDescriptor]
                )
            ],
            manifests: [
                manifestDigest: Self.manifest(configDigest: configDigest)
            ],
            configs: [
                configDigest: Self.config(
                    architecture: "arm64",
                    label: "runnable-occurrence"
                )
            ]
        )
        let descriptors = try await RunnableImageSelector(
            contentProvider: provider
        ).descriptors(for: Self.clientImage(rootDigest: rootDigest))

        #expect(descriptors.map(\.kind) == [.artifact, .image])
        #expect(descriptors.first?.artifactSubjectDigest == subjectDigest)
        #expect(descriptors.first?.runnableVariant == nil)
        #expect(descriptors.last?.runnableVariant != nil)
        #expect(await provider.contentRequests().configs == [configDigest])
    }

    @Test("graphs deeper than the traversal bound fail closed")
    func excessiveIndexDepth() async throws {
        let rootDigest = Self.numberedDigest(150)
        let manifestDigest = Self.numberedDigest(250)
        let configDigest = Self.numberedDigest(251)
        var indexes: [String: Index] = [:]
        indexes[rootDigest] = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.index,
                    digest: Self.numberedDigest(151),
                    size: 10
                )
            ]
        )
        for offset in 0..<32 {
            let digest = Self.numberedDigest(151 + offset)
            let child: Descriptor
            if offset == 31 {
                child = Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 10,
                    platform: Platform(arch: "arm64", os: "linux")
                )
            } else {
                child = Descriptor(
                    mediaType: MediaTypes.index,
                    digest: Self.numberedDigest(152 + offset),
                    size: 10
                )
            }
            indexes[digest] = Index(manifests: [child])
        }
        let provider = RecordingRunnableImageContentProvider(
            indexes: indexes,
            manifests: [
                manifestDigest: Self.manifest(configDigest: configDigest)
            ],
            configs: [
                configDigest: Self.config(
                    architecture: "arm64",
                    label: "too-deep"
                )
            ]
        )

        await #expect(throws: OCIImageGraphError.indexNestingTooDeep) {
            try await RunnableImageSelector(
                contentProvider: provider
            ).descriptors(for: Self.clientImage(rootDigest: rootDigest))
        }
    }

    @Test("host preference and same-platform ties are stable across index order")
    func deterministicPreferredSelection() async throws {
        let host = Platform(arch: "arm64", os: "linux", variant: "v8")
        let other = Platform(arch: "amd64", os: "linux")
        let largerDigest = Self.digest("f")
        let smallerDigest = Self.digest("1")
        let otherDigest = Self.digest("2")
        let variants = [
            RunnableImageVariant(
                descriptor: Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: largerDigest,
                    size: 1,
                    platform: host
                ),
                platform: host,
                manifest: Self.manifest(configDigest: Self.digest("3")),
                config: Self.config(architecture: "arm64", label: "larger")
            ),
            RunnableImageVariant(
                descriptor: Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: smallerDigest,
                    size: 1,
                    platform: host
                ),
                platform: host,
                manifest: Self.manifest(configDigest: Self.digest("4")),
                config: Self.config(architecture: "arm64", label: "smaller")
            ),
            RunnableImageVariant(
                descriptor: Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: otherDigest,
                    size: 1,
                    platform: other
                ),
                platform: other,
                manifest: Self.manifest(configDigest: Self.digest("5")),
                config: Self.config(architecture: "amd64", label: "other")
            ),
        ]
        let resolved = variants.map {
            ResolvedImageDescriptor(
                descriptor: $0.descriptor,
                manifest: $0.manifest,
                kind: .image,
                runnableVariant: $0
            )
        }
        let selector = RunnableImageSelector(
            contentProvider: RecordingRunnableImageContentProvider(
                indexes: [:],
                manifests: [:],
                configs: [:]
            )
        )

        #expect(
            selector.selectVariant(
                from: resolved,
                requestedPlatform: nil,
                hostPlatform: host
            )?.descriptor.digest == smallerDigest
        )
        #expect(
            selector.selectVariant(
                from: resolved.reversed(),
                requestedPlatform: nil,
                hostPlatform: host
            )?.descriptor.digest == smallerDigest
        )
    }
}
