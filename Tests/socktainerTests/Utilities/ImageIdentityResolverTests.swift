import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

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
            if let listDelay { try await Task.sleep(for: listDelay) }
            return images
        }

        func index(for image: ClientImage) async throws -> Index {
            indexes[image.digest]!
        }

        func manifest(digest: String) async throws -> Manifest? {
            manifests[digest]
        }

        func replace(images: [ClientImage], indexes: [String: Index], manifests: [String: Manifest]) {
            self.images = images
            self.indexes = indexes
            self.manifests = manifests
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

    private static func fixture(
        reference: String = "docker.io/library/example:latest",
        rootCharacter: Character = "1",
        manifestCharacter: Character = "2",
        configDigest: String? = nil,
        includeAttestation: Bool = true,
        annotatedName: String? = nil
    ) -> Fixture {
        let root = digest(rootCharacter)
        let runnableManifest = digest(manifestCharacter)
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
            annotations: ["vnd.docker.reference.type": "attestation-manifest"],
            platform: unknown
        )
        let index = Index(manifests: includeAttestation ? [runnableDescriptor, artifactDescriptor] : [runnableDescriptor])
        let runnable = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: config, size: 20),
            layers: []
        )
        let artifact = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: artifactConfig, size: 10),
            layers: []
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
            manifests: includeAttestation
                ? [runnableManifest: runnable, artifactManifest: artifact]
                : [runnableManifest: runnable],
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

    @Test("root, manifest, and config digests round-trip exactly and by prefix")
    func allRunnableDigestForms() async throws {
        let fixture = Self.fixture()
        let (resolver, _) = Self.resolver([fixture])

        #expect(try await resolver.resolve(fixture.root).kind == .root)
        #expect(try await resolver.resolve(String(fixture.manifest.dropFirst(7))).impliedPlatform?.architecture == "arm64")
        #expect(try await resolver.resolve(String(fixture.config.prefix(15))).impliedPlatform?.architecture == "arm64")
    }

    @Test("repository digests remain scoped to their repository")
    func repositoryScope() async throws {
        let fixture = Self.fixture()
        let (resolver, _) = Self.resolver([fixture])

        #expect(
            try await resolver.resolve("docker.io/library/example@\(fixture.manifest)").reference
                == fixture.image.reference
        )
        #expect(try await resolver.resolve("example@\(fixture.manifest)").reference == fixture.image.reference)
        await #expect(throws: ImageIdentityResolutionError.notFound("docker.io/library/other@\(fixture.manifest)")) {
            try await resolver.resolve("docker.io/library/other@\(fixture.manifest)")
        }
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
