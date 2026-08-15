import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing

@testable import GlassDock

@Suite("Docker image identity resolver")
struct ImageIdentityResolverTests {
    private enum BackendFailure: Error, Equatable {
        case unavailable
    }

    private struct FailingCatalog: ImageIdentityCatalog {
        func list() async throws -> [ClientImage] { throw BackendFailure.unavailable }
        func index(for image: ClientImage) async throws -> Index { throw BackendFailure.unavailable }
        func manifest(digest: String) async throws -> Manifest? { throw BackendFailure.unavailable }
    }

    private actor Catalog: ImageIdentityCatalog {
        var images: [ClientImage]
        var indexes: [String: Index]
        var manifests: [String: Manifest]
        var listCalls = 0
        let listDelay: Duration?

        init(
            images: [ClientImage],
            indexes: [String: Index],
            manifests: [String: Manifest],
            listDelay: Duration? = nil
        ) {
            self.images = images
            self.indexes = indexes
            self.manifests = manifests
            self.listDelay = listDelay
        }

        func list() async throws -> [ClientImage] {
            listCalls += 1
            let snapshot = images
            if let listDelay { try await Task.sleep(for: listDelay) }
            return snapshot
        }

        func index(for image: ClientImage) async throws -> Index {
            guard let index = indexes[image.digest] else {
                throw ContainerizationError(
                    .notFound,
                    message: "content with digest \(image.digest)"
                )
            }
            return index
        }

        func index(digest: String) async throws -> Index? {
            indexes[digest]
        }

        func manifest(digest: String) async throws -> Manifest? {
            manifests[digest]
        }

        func replace(images: [ClientImage], indexes: [String: Index], manifests: [String: Manifest]) {
            self.images = images
            // An in-flight catalog snapshot may still hydrate the old roots.
            // Retain immutable content documents while replacing references,
            // matching the content-addressed production store.
            self.indexes.merge(indexes) { _, replacement in replacement }
            self.manifests.merge(manifests) { _, replacement in replacement }
        }

        func count() -> Int { listCalls }
    }

    private struct Fixture {
        let image: ClientImage
        let index: Index
        let manifests: [String: Manifest]
        let root: String
        let manifest: String
        let config: String
        let artifactManifest: String
        let artifactConfig: String
    }

    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private static func numberedDigest(_ value: Int) -> String {
        "sha256:" + String(format: "%064x", value)
    }

    private static func fixture(
        reference: String = "docker.io/library/example:latest",
        rootCharacter: Character = "1",
        manifestCharacter: Character = "2",
        manifestDigest: String? = nil,
        configDigest: String? = nil,
        includeRunnable: Bool = true,
        includeAttestation: Bool = true,
        artifactDescriptorAnnotated: Bool = true,
        artifactManifestAnnotations: [String: String]? = nil,
        artifactUsesRunnablePlatform: Bool = false,
        annotatedName: String? = nil
    ) -> Fixture {
        let root = digest(rootCharacter)
        let runnableManifest = manifestDigest ?? digest(manifestCharacter)
        let config = configDigest ?? digest("3")
        let artifactManifest = digest("a")
        let artifactConfig = digest("b")
        let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)
        let unknown = Platform(arch: "unknown", os: "unknown", variant: nil)
        let runnableDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: runnableManifest,
            size: 100,
            platform: arm64
        )
        let artifactDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: artifactManifest,
            size: 40,
            annotations: artifactDescriptorAnnotated
                ? ["vnd.docker.reference.type": "attestation-manifest"]
                : nil,
            platform: artifactUsesRunnablePlatform ? arm64 : unknown
        )
        let index = Index(
            manifests: (includeRunnable ? [runnableDescriptor] : [])
                + (includeAttestation ? [artifactDescriptor] : [])
        )
        let runnable = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: config, size: 20),
            layers: []
        )
        let artifact = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: artifactConfig, size: 10),
            layers: [],
            annotations: artifactManifestAnnotations
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: root,
                    size: 200,
                    annotations: annotatedName.map {
                        [AnnotationKeys.containerizationImageName: $0]
                    }
                )
            ))
        return Fixture(
            image: image,
            index: index,
            manifests: Dictionary(
                uniqueKeysWithValues: (includeRunnable ? [(runnableManifest, runnable)] : [])
                    + (includeAttestation
                        ? [(artifactManifest, artifact)] : [])
            ),
            root: root,
            manifest: runnableManifest,
            config: config,
            artifactManifest: artifactManifest,
            artifactConfig: artifactConfig
        )
    }

    private static func resolver(_ fixtures: [Fixture]) -> (ImageIdentityResolver, Catalog) {
        let catalog = Catalog(
            images: fixtures.map(\.image),
            indexes: Dictionary(fixtures.map { ($0.root, $0.index) }, uniquingKeysWith: { first, _ in first }),
            manifests: fixtures.reduce(into: [:]) { result, fixture in
                result.merge(fixture.manifests) { first, _ in first }
            }
        )
        return (ImageIdentityResolver(systemConfig: ContainerSystemConfig(), catalog: catalog), catalog)
    }

    @Test("full, familiar, and tagless references resolve without rebuilding")
    func referenceAliases() async throws {
        let fixture = Self.fixture()
        let (resolver, catalog) = Self.resolver([fixture])

        #expect(try await resolver.resolve("docker.io/library/example:latest").reference == fixture.image.reference)
        #expect(try await resolver.resolve("example:latest").reference == fixture.image.reference)
        #expect(try await resolver.resolve("example").reference == fixture.image.reference)
        #expect(await catalog.count() == 1)
    }

    @Test("a locally built image's OCI name annotation is an indexed alias")
    func localAnnotationAlias() async throws {
        let fixture = Self.fixture(
            reference: "untagged@\(Self.digest("d"))",
            annotatedName: "docker.io/library/local-build:latest"
        )
        let (resolver, _) = Self.resolver([fixture])

        #expect(try await resolver.resolve("local-build").reference == fixture.image.reference)
    }

    @Test("an OCI name annotation cannot shadow an exact stored reference")
    func annotationCannotShadowStoredReference() async throws {
        let exact = Self.fixture(
            reference: "docker.io/library/example:latest",
            rootCharacter: "1",
            manifestCharacter: "2"
        )
        let annotated = Self.fixture(
            reference: "untagged@\(Self.digest("d"))",
            rootCharacter: "8",
            manifestCharacter: "9",
            configDigest: Self.digest("c"),
            annotatedName: "docker.io/library/example:latest"
        )
        let (resolver, _) = Self.resolver([exact, annotated])

        #expect(try await resolver.resolve("example").reference == exact.image.reference)
    }

    @Test("colliding annotation aliases are ambiguous instead of selecting by store order")
    func collidingAnnotationsAreAmbiguous() async throws {
        let first = Self.fixture(
            reference: "untagged@\(Self.digest("d"))",
            rootCharacter: "4",
            manifestCharacter: "5",
            configDigest: Self.digest("6"),
            annotatedName: "docker.io/library/collision:latest"
        )
        let second = Self.fixture(
            reference: "untagged@\(Self.digest("e"))",
            rootCharacter: "7",
            manifestCharacter: "8",
            configDigest: Self.digest("9"),
            annotatedName: "docker.io/library/collision:latest"
        )
        let (resolver, _) = Self.resolver([first, second])

        await #expect(throws: ImageIdentityResolutionError.ambiguous("collision")) {
            try await resolver.resolve("collision")
        }
    }

    @Test("a named tag resolves to that exact stored reference when tags share a root")
    func exactTagAmongSharedRoot() async throws {
        let first = Self.fixture(reference: "docker.io/library/example:first")
        let second = Self.fixture(reference: "docker.io/library/example:second")
        let (resolver, _) = Self.resolver([first, second])

        #expect(try await resolver.resolve("example:second").reference == second.image.reference)
        #expect(try await resolver.resolve(second.config).references.count == 2)
    }

    @Test("an exact canonical key owns a tag over a stale familiar key on another root")
    func canonicalKeyReplacesFamiliarRoot() async throws {
        let displaced = Self.fixture(
            reference: "example:latest",
            rootCharacter: "4",
            manifestCharacter: "5",
            configDigest: Self.digest("6")
        )
        let owner = Self.fixture(
            reference: "docker.io/library/example:latest",
            rootCharacter: "7",
            manifestCharacter: "8",
            configDigest: Self.digest("9")
        )
        let (resolver, _) = Self.resolver([displaced, owner])

        #expect(try await resolver.resolve("example").image.digest == owner.root)
        #expect(try await resolver.resolve("example:latest").image.digest == owner.root)
        #expect(
            try await resolver.resolve("docker.io/library/example:latest").image.digest
                == owner.root
        )

        let oldByRoot = try await resolver.resolve(displaced.root)
        #expect(oldByRoot.image.digest == displaced.root)
        #expect(oldByRoot.references.isEmpty)
        #expect(oldByRoot.storeReferences == [displaced.image.reference])
        #expect(try await resolver.resolve(displaced.config).image.digest == displaced.root)
    }

    @Test("two noncanonical roots remain a true tag ambiguity")
    func noncanonicalRootsRemainAmbiguous() async throws {
        let first = Self.fixture(
            reference: "example:latest",
            rootCharacter: "4",
            manifestCharacter: "5",
            configDigest: Self.digest("6")
        )
        let second = Self.fixture(
            reference: "library/example:latest",
            rootCharacter: "7",
            manifestCharacter: "8",
            configDigest: Self.digest("9")
        )
        let (resolver, _) = Self.resolver([first, second])

        await #expect(throws: ImageIdentityResolutionError.ambiguous("example")) {
            try await resolver.resolve("example")
        }
    }

    @Test("a preservation reference never resurrects its historical name annotation")
    func preservationAnnotationDoesNotResurrectTag() async throws {
        let displaced = Self.fixture(
            reference: "moby-dangling@\(Self.digest("4"))",
            rootCharacter: "4",
            manifestCharacter: "5",
            configDigest: Self.digest("6"),
            annotatedName: "docker.io/library/example:latest"
        )
        let (resolver, _) = Self.resolver([displaced])

        await #expect(throws: ImageIdentityResolutionError.notFound("example")) {
            try await resolver.resolve("example")
        }
        let resolved = try await resolver.resolve(displaced.root)
        #expect(resolved.image.digest == displaced.root)
        #expect(resolved.repositoryDigests.isEmpty)
    }

    @Test("a bare physical digest is indexed only as an immutable image ID")
    func bareDigestIsNotTagOwnership() async throws {
        let fixture = Self.fixture(
            reference: Self.digest("1"),
            rootCharacter: "1"
        )
        let (resolver, _) = Self.resolver([fixture])

        let resolved = try await resolver.resolve(fixture.root)
        #expect(resolved.kind == .root)
        #expect(resolved.references.isEmpty)
        #expect(resolved.storeReferences == [fixture.root])

        let bogusTag =
            "docker.io/library/sha256:"
            + String(repeating: "1", count: 64)
        await #expect(
            throws: ImageIdentityResolutionError.notFound(bogusTag)
        ) {
            try await resolver.resolve(bogusTag)
        }
    }

    @Test("root, manifest, and config digests round-trip exactly and by prefix")
    func allRunnableDigestForms() async throws {
        let fixture = Self.fixture()
        let (resolver, _) = Self.resolver([fixture])

        #expect(try await resolver.resolve(fixture.root).kind == .root)
        #expect(try await resolver.resolve(String(fixture.manifest.dropFirst(7))).impliedPlatform?.architecture == "arm64")
        #expect(try await resolver.resolve(String(fixture.config.prefix(15))).impliedPlatform?.architecture == "arm64")
    }

    @Test("nested runnable index, manifest, and config identities round-trip")
    func nestedRunnableIdentities() async throws {
        let rootDigest = Self.numberedDigest(1000)
        let nestedIndexDigest = Self.numberedDigest(1001)
        let armManifestDigest = Self.numberedDigest(1002)
        let amdManifestDigest = Self.numberedDigest(1003)
        let armConfigDigest = Self.numberedDigest(1004)
        let amdConfigDigest = Self.numberedDigest(1005)
        let arm = Platform(arch: "arm64", os: "linux")
        let amd = Platform(arch: "amd64", os: "linux")
        let image = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/nested:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: rootDigest,
                    size: 200
                )
            )
        )
        let catalog = Catalog(
            images: [image],
            indexes: [
                rootDigest: Index(
                    manifests: [
                        Descriptor(
                            mediaType: MediaTypes.index,
                            digest: nestedIndexDigest,
                            size: 100
                        )
                    ]
                ),
                nestedIndexDigest: Index(
                    manifests: [
                        Descriptor(
                            mediaType: MediaTypes.imageManifest,
                            digest: amdManifestDigest,
                            size: 50,
                            platform: amd
                        ),
                        Descriptor(
                            mediaType: MediaTypes.imageManifest,
                            digest: armManifestDigest,
                            size: 50,
                            platform: arm
                        ),
                    ]
                ),
            ],
            manifests: [
                armManifestDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: armConfigDigest,
                        size: 20
                    ),
                    layers: []
                ),
                amdManifestDigest: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: amdConfigDigest,
                        size: 20
                    ),
                    layers: []
                ),
            ]
        )
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog
        )

        let nested = try await resolver.resolve(nestedIndexDigest)
        #expect(nested.kind == .root)
        #expect(nested.impliedPlatform == nil)
        #expect(nested.image.digest == rootDigest)
        #expect(
            try await resolver.resolve(armManifestDigest).kind
                == .manifest(arm)
        )
        #expect(
            try await resolver.resolve(amdConfigDigest).kind
                == .config(amd)
        )
        await #expect(
            throws: ImageIdentityResolutionError.notFound(
                "docker.io/library/nested@\(nestedIndexDigest)"
            )
        ) {
            try await resolver.resolve(
                "docker.io/library/nested@\(nestedIndexDigest)"
            )
        }
    }

    @Test("one missing root blob cannot poison unrelated identity hydration")
    func missingRootIsIsolated() async throws {
        let good = Self.fixture(
            reference: "docker.io/library/good:latest",
            rootCharacter: "e",
            manifestCharacter: "d",
            configDigest: Self.digest("c"),
            includeAttestation: false
        )
        let missingRoot = Self.numberedDigest(1099)
        let missingImage = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/missing-root:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: missingRoot,
                    size: 100
                )
            )
        )
        let catalog = Catalog(
            images: [missingImage, good.image],
            indexes: [good.root: good.index],
            manifests: good.manifests
        )
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog
        )

        #expect(
            try await resolver.resolve("good").image.digest == good.root
        )
        await #expect(
            throws: ImageIdentityResolutionError.nonRunnable(
                "missing-root"
            )
        ) {
            try await resolver.resolve("missing-root")
        }
    }

    @Test("one over-deep root cannot poison unrelated identity hydration")
    func overDeepRootIsIsolated() async throws {
        let badRoot = Self.numberedDigest(1100)
        let good = Self.fixture(
            reference: "docker.io/library/good:latest",
            rootCharacter: "e",
            manifestCharacter: "d",
            configDigest: Self.digest("c"),
            includeAttestation: false
        )
        let badImage = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/depth-bomb:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: badRoot,
                    size: 100
                )
            )
        )
        var indexes = [good.root: good.index]
        indexes[badRoot] = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.index,
                    digest: Self.numberedDigest(1101),
                    size: 10
                )
            ]
        )
        for offset in 0..<32 {
            let digest = Self.numberedDigest(1101 + offset)
            let child = Descriptor(
                mediaType: offset == 31
                    ? MediaTypes.imageManifest : MediaTypes.index,
                digest: Self.numberedDigest(1102 + offset),
                size: 10,
                platform: offset == 31
                    ? Platform(arch: "arm64", os: "linux") : nil
            )
            indexes[digest] = Index(manifests: [child])
        }
        let catalog = Catalog(
            images: [badImage, good.image],
            indexes: indexes,
            manifests: good.manifests
        )
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog
        )

        #expect(
            try await resolver.resolve("good").image.digest == good.root
        )
        await #expect(
            throws: ImageIdentityResolutionError.nonRunnable(
                "depth-bomb"
            )
        ) {
            try await resolver.resolve("depth-bomb")
        }
    }

    @Test("a local tag does not synthesize a repository digest association")
    func repositoryDigestRequiresPhysicalAssociation() async throws {
        let fixture = Self.fixture()
        let (resolver, _) = Self.resolver([fixture])

        for scoped in [
            "docker.io/library/example@\(fixture.manifest)",
            "example@\(fixture.manifest)",
            "docker.io/library/other@\(fixture.manifest)",
        ] {
            await #expect(
                throws: ImageIdentityResolutionError.notFound(scoped)
            ) {
                try await resolver.resolve(scoped)
            }
        }
    }

    @Test("a physical repository digest preserves manifest identity and platform")
    func physicalRepositoryManifestDigest() async throws {
        let manifestDigest = Self.digest("2")
        let physicalReference =
            "docker.io/library/example@\(manifestDigest)"
        let fixture = Self.fixture(reference: physicalReference)
        let (resolver, _) = Self.resolver([fixture])

        let resolved = try await resolver.resolve(physicalReference)
        #expect(resolved.kind == .manifest(Platform(arch: "arm64", os: "linux")))
        #expect(resolved.impliedPlatform?.architecture == "arm64")
        #expect(resolved.references.isEmpty)
        #expect(resolved.repositoryDigests == [physicalReference])
        #expect(
            try await resolver.resolve("example@\(manifestDigest)").kind
                == resolved.kind
        )
    }

    @Test("repository scoping requires the exact physical digest association")
    func repositoryScopeDoesNotAuthorizeSiblingDigest() async throws {
        let rootDigest = Self.digest("1")
        let physicalReference = "docker.io/library/example@\(rootDigest)"
        let fixture = Self.fixture(reference: physicalReference)
        let (resolver, _) = Self.resolver([fixture])

        #expect(
            try await resolver.resolve(physicalReference).image.digest
                == fixture.root
        )
        await #expect(
            throws: ImageIdentityResolutionError.notFound(
                "docker.io/library/example@\(fixture.manifest)"
            )
        ) {
            try await resolver.resolve(
                "docker.io/library/example@\(fixture.manifest)"
            )
        }
    }

    @Test("an inconsistent physical repository digest is not indexed as an alias")
    func inconsistentPhysicalRepositoryDigest() async throws {
        let unrelatedDigest = Self.digest("f")
        let physicalReference =
            "docker.io/library/example@\(unrelatedDigest)"
        let fixture = Self.fixture(reference: physicalReference)
        let (resolver, _) = Self.resolver([fixture])

        await #expect(
            throws: ImageIdentityResolutionError.notFound(physicalReference)
        ) {
            try await resolver.resolve(physicalReference)
        }
        let root = try await resolver.resolve(fixture.root)
        #expect(root.repositoryDigests.isEmpty)
    }

    @Test("digest prefixes are rejected when they identify distinct roots")
    func ambiguousPrefix() async throws {
        let configOne = "sha256:dead" + String(repeating: "1", count: 60)
        let configTwo = "sha256:dead" + String(repeating: "2", count: 60)
        let one = Self.fixture(reference: "docker.io/library/one:latest", rootCharacter: "4", manifestCharacter: "5", configDigest: configOne)
        let two = Self.fixture(reference: "docker.io/library/two:latest", rootCharacter: "6", manifestCharacter: "7", configDigest: configTwo)
        let (resolver, _) = Self.resolver([one, two])

        await #expect(throws: ImageIdentityResolutionError.ambiguous("dead")) {
            try await resolver.resolve("dead")
        }
    }

    @Test("a full config digest shared by distinct roots remains one immutable image ID")
    func sharedConfigDigestRoundTripsAcrossRoots() async throws {
        let sharedConfig = Self.digest("c")
        let one = Self.fixture(
            reference: "docker.io/library/one:latest",
            rootCharacter: "4",
            manifestCharacter: "5",
            configDigest: sharedConfig
        )
        let two = Self.fixture(
            reference: "docker.io/library/two:latest",
            rootCharacter: "6",
            manifestCharacter: "7",
            configDigest: sharedConfig
        )
        let (resolver, _) = Self.resolver([one, two])

        let resolved = try await resolver.resolve(sharedConfig)

        #expect(resolved.kind == .config(Platform(arch: "arm64", os: "linux")))
        #expect(resolved.image.digest == one.root)
        #expect(resolved.rootDigests == [one.root, two.root])
        #expect(
            resolved.references
                == [
                    "docker.io/library/one:latest",
                    "docker.io/library/two:latest",
                ]
        )
        #expect(resolved.dockerConfigDigest == sharedConfig)
        #expect(
            resolved.variantConstraint
                == .exactManifest(
                    manifestDigest: one.manifest,
                    configDigest: sharedConfig
                )
        )
    }

    @Test("a config digest with multiple parent manifests in one root selects deterministically")
    func sharedConfigDigestAcrossSiblingManifests() async throws {
        let rootDigest = Self.numberedDigest(700)
        let firstManifest = Self.numberedDigest(701)
        let secondManifest = Self.numberedDigest(702)
        let sharedConfig = Self.numberedDigest(703)
        let platform = Platform(arch: "arm64", os: "linux")
        let image = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/recompressed:latest",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: rootDigest,
                    size: 200
                )
            )
        )
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: sharedConfig,
                size: 20
            ),
            layers: []
        )
        let catalog = Catalog(
            images: [image],
            indexes: [
                rootDigest: Index(
                    manifests: [
                        Descriptor(
                            mediaType: MediaTypes.imageManifest,
                            digest: secondManifest,
                            size: 50,
                            platform: platform
                        ),
                        Descriptor(
                            mediaType: MediaTypes.imageManifest,
                            digest: firstManifest,
                            size: 50,
                            platform: platform
                        ),
                    ]
                )
            ],
            manifests: [
                firstManifest: manifest,
                secondManifest: manifest,
            ]
        )
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog
        )

        for _ in 0..<3 {
            let resolved = try await resolver.resolve(sharedConfig)
            #expect(resolved.kind == .config(platform))
            #expect(resolved.image.digest == rootDigest)
            #expect(
                resolved.variantConstraint
                    == .exactManifest(
                        manifestDigest: firstManifest,
                        configDigest: sharedConfig
                    )
            )
            await resolver.invalidate()
        }
    }

    @Test("a manifest shared by plain and attested roots remains one immutable ID")
    func sharedManifestRoundTripsAcrossRoots() async throws {
        let sharedManifest = Self.digest("5")
        let sharedConfig = Self.digest("c")
        let attested = Self.fixture(
            reference: "docker.io/library/attested:latest",
            rootCharacter: "4",
            manifestDigest: sharedManifest,
            configDigest: sharedConfig,
            includeAttestation: true
        )
        let plain = Self.fixture(
            reference: "docker.io/library/plain:latest",
            rootCharacter: "6",
            manifestDigest: sharedManifest,
            configDigest: sharedConfig,
            includeAttestation: false
        )
        let (resolver, _) = Self.resolver([plain, attested])

        let resolved = try await resolver.resolve(sharedManifest)

        #expect(resolved.kind == .manifest(Platform(arch: "arm64", os: "linux")))
        #expect(resolved.image.digest == attested.root)
        #expect(resolved.rootDigests == [attested.root, plain.root])
        #expect(
            resolved.references
                == [
                    "docker.io/library/attested:latest",
                    "docker.io/library/plain:latest",
                ]
        )
        #expect(resolved.dockerConfigDigest == sharedConfig)
        #expect(
            resolved.variantConstraint
                == .exactManifest(
                    manifestDigest: sharedManifest,
                    configDigest: sharedConfig
                )
        )
    }

    @Test("repository-scoped config IDs are rejected while the bare config ID resolves")
    func repositoryScopedConfigIsNotDistributionDigest() async throws {
        let fixture = Self.fixture()
        let (resolver, _) = Self.resolver([fixture])
        let scoped = "docker.io/library/example@\(fixture.config)"

        #expect(
            try await resolver.resolve(fixture.config).kind
                == .config(
                    Platform(arch: "arm64", os: "linux")
                ))
        await #expect(
            throws: ImageIdentityResolutionError.notFound(scoped)
        ) {
            try await resolver.resolve(scoped)
        }
    }

    @Test("a physical repository-scoped config key is not emitted or resolved")
    func physicalRepositoryConfigIsHidden() async throws {
        let configDigest = Self.digest("c")
        let physicalReference =
            "docker.io/library/example@\(configDigest)"
        let fixture = Self.fixture(
            reference: physicalReference,
            configDigest: configDigest
        )
        let (resolver, _) = Self.resolver([fixture])

        await #expect(
            throws: ImageIdentityResolutionError.notFound(
                physicalReference
            )
        ) {
            try await resolver.resolve(physicalReference)
        }
        let bare = try await resolver.resolve(configDigest)
        #expect(bare.repositoryDigests.isEmpty)
    }

    @Test("attestation manifest and payload identities never select a runnable image")
    func attestationIsNotRunnable() async throws {
        let fixture = Self.fixture()
        let (resolver, _) = Self.resolver([fixture])

        await #expect(throws: ImageIdentityResolutionError.nonRunnable(fixture.artifactManifest)) {
            try await resolver.resolve(fixture.artifactManifest)
        }
        await #expect(throws: ImageIdentityResolutionError.nonRunnable(fixture.artifactConfig)) {
            try await resolver.resolve(fixture.artifactConfig)
        }
    }

    @Test("an artifact-only root cannot resolve as a runnable image")
    func artifactOnlyRootIsNonRunnable() async throws {
        let fixture = Self.fixture(includeRunnable: false)
        let (resolver, _) = Self.resolver([fixture])

        await #expect(
            throws: ImageIdentityResolutionError.nonRunnable("example")
        ) {
            try await resolver.resolve("example")
        }
        await #expect(
            throws: ImageIdentityResolutionError.nonRunnable(fixture.root)
        ) {
            try await resolver.resolve(fixture.root)
        }
    }

    @Test("a manifest-level BuildKit marker stays non-runnable")
    func manifestAnnotatedArtifactIsNonRunnable() async throws {
        let fixture = Self.fixture(
            artifactDescriptorAnnotated: false,
            artifactManifestAnnotations: [
                "vnd.docker.reference.type": "attestation-manifest"
            ],
            artifactUsesRunnablePlatform: true
        )
        let (resolver, _) = Self.resolver([fixture])

        await #expect(
            throws: ImageIdentityResolutionError.nonRunnable(
                fixture.artifactManifest
            )
        ) {
            try await resolver.resolve(fixture.artifactManifest)
        }
        await #expect(
            throws: ImageIdentityResolutionError.nonRunnable(
                fixture.artifactConfig
            )
        ) {
            try await resolver.resolve(fixture.artifactConfig)
        }
    }

    @Test("a digest shared by runnable config and artifact payload remains runnable")
    func runnableDigestWinsOverArtifactClassification() async throws {
        let sharedDigest = Self.digest("b")
        let fixture = Self.fixture(configDigest: sharedDigest)
        let (resolver, _) = Self.resolver([fixture])

        let exact = try await resolver.resolve(sharedDigest)
        #expect(
            exact.kind
                == .config(Platform(arch: "arm64", os: "linux"))
        )
        await #expect(
            throws: ImageIdentityResolutionError.notFound(
                "docker.io/library/example@\(sharedDigest)"
            )
        ) {
            try await resolver.resolve(
                "docker.io/library/example@\(sharedDigest)"
            )
        }
    }

    @Test("a prefix matching two digests in one root remains ambiguous")
    func sameRootPrefixCollisionIsAmbiguous() async throws {
        let manifest = "sha256:dead" + String(repeating: "1", count: 60)
        let config = "sha256:dead" + String(repeating: "2", count: 60)
        let fixture = Self.fixture(
            manifestDigest: manifest,
            configDigest: config,
            includeAttestation: false
        )
        let (resolver, _) = Self.resolver([fixture])

        await #expect(
            throws: ImageIdentityResolutionError.ambiguous("dead")
        ) {
            try await resolver.resolve("dead")
        }
    }

    @Test("a physical repository-scoped attestation remains non-runnable")
    func physicalRepositoryAttestationIsNotRunnable() async throws {
        let artifactDigest = Self.digest("a")
        let physicalReference =
            "docker.io/library/example@\(artifactDigest)"
        let fixture = Self.fixture(reference: physicalReference)
        let (resolver, _) = Self.resolver([fixture])

        await #expect(
            throws: ImageIdentityResolutionError.nonRunnable(
                physicalReference
            )
        ) {
            try await resolver.resolve(physicalReference)
        }
        await #expect(
            throws: ImageIdentityResolutionError.notFound(
                "docker.io/library/other@\(artifactDigest)"
            )
        ) {
            try await resolver.resolve(
                "docker.io/library/other@\(artifactDigest)"
            )
        }
    }

    @Test("invalid and too-short IDs are not treated as digest prefixes")
    func invalidIDs() async throws {
        let fixture = Self.fixture()
        let (resolver, _) = Self.resolver([fixture])

        for value in ["123", "SHA256:" + String(repeating: "1", count: 64), "zzzz", String(repeating: "1", count: 65)] {
            await #expect(throws: ImageIdentityResolutionError.notFound(value)) {
                try await resolver.resolve(value)
            }
        }
    }

    @Test("explicit refresh atomically invalidates removed and added identities")
    func refreshInvalidation() async throws {
        let old = Self.fixture(reference: "docker.io/library/old:latest")
        let new = Self.fixture(reference: "docker.io/library/new:latest", rootCharacter: "8", manifestCharacter: "9", configDigest: Self.digest("c"), includeAttestation: false)
        let (resolver, catalog) = Self.resolver([old])
        _ = try await resolver.resolve(old.config)

        await catalog.replace(images: [new.image], indexes: [new.root: new.index], manifests: new.manifests)
        try await resolver.refresh()

        await #expect(throws: ImageIdentityResolutionError.notFound(old.config)) {
            try await resolver.resolve(old.config)
        }
        #expect(try await resolver.resolve(new.config).reference == new.image.reference)
        #expect(await catalog.count() == 2)
    }

    @Test("an external Apple state-file replacement invalidates the snapshot")
    func externalStateInvalidation() async throws {
        let fixture = Self.fixture()
        let catalog = Catalog(
            images: [fixture.image],
            indexes: [fixture.root: fixture.index],
            manifests: fixture.manifests
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog,
            appSupportURL: directory
        )

        _ = try await resolver.resolve("example")
        try Data("first".utf8).write(to: directory.appendingPathComponent("state.json"))
        _ = try await resolver.resolve("example")

        #expect(await catalog.count() == 2)
    }

    @Test("concurrent cold lookups coalesce into one store hydration")
    func concurrentColdLookupsAreCoalesced() async throws {
        let fixture = Self.fixture()
        let catalog = Catalog(
            images: [fixture.image],
            indexes: [fixture.root: fixture.index],
            manifests: fixture.manifests,
            listDelay: .milliseconds(50)
        )
        let resolver = ImageIdentityResolver(systemConfig: ContainerSystemConfig(), catalog: catalog)

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await resolver.resolve("example").reference }
            }
            for try await reference in group {
                #expect(reference == fixture.image.reference)
            }
        }

        #expect(await catalog.count() == 1)
    }

    @Test("a refresh overlapping a mutation cannot publish the old catalog")
    func overlappingRefreshRetriesInNewEpoch() async throws {
        let old = Self.fixture(reference: "docker.io/library/old:latest")
        let new = Self.fixture(
            reference: "docker.io/library/new:latest",
            rootCharacter: "8",
            manifestCharacter: "9",
            configDigest: Self.digest("c"),
            includeAttestation: false
        )
        let catalog = Catalog(
            images: [old.image],
            indexes: [old.root: old.index, new.root: new.index],
            manifests: old.manifests.merging(new.manifests) { first, _ in first },
            listDelay: .milliseconds(100)
        )
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog,
            mutationCoordinator: coordinator
        )

        let reader = Task {
            try await resolver.resolve("new").image.digest
        }
        while await catalog.count() == 0 {
            await Task.yield()
        }

        try await coordinator.performMutation {
            await catalog.replace(
                images: [new.image],
                indexes: [new.root: new.index],
                manifests: new.manifests
            )
            await resolver.invalidate()
        }

        #expect(try await reader.value == new.root)
        #expect(await catalog.count() >= 2)
    }

    @Test("image service preserves backend failures instead of converting them to not-found")
    func servicePreservesBackendFailure() async throws {
        let config = ContainerSystemConfig()
        let resolver = ImageIdentityResolver(systemConfig: config, catalog: FailingCatalog())
        let service = ClientImageService(containerSystemConfig: config, identityResolver: resolver)

        await #expect(throws: BackendFailure.unavailable) {
            try await service.delete(id: "example")
        }
    }
}
