import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import GlassDock

@Suite("ClientImageService load")
struct ClientImageServiceLoadTests {

    @Test("a single-manifest OCI tarball loads")
    func baselineTarballLoads() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [fixture.tagged(manifest, as: "crafted-baseline:latest")])

        let loaded = try await fixture.load(fixture.makeTarball())

        #expect(loaded == ["docker.io/library/crafted-baseline:latest"])
        let stored = try await ImageStore(path: fixture.storeDir).get(reference: "docker.io/library/crafted-baseline:latest")
        let storedIndex = try await stored.index()
        #expect(storedIndex.manifests.map(\.digest) == [manifest.digest])
    }

    @Test(
        "a compressed tarball loads",
        arguments: [Filter.gzip, .bzip2, .xz, .zstd]
    )
    func compressedTarballLoads(compression: Filter) async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [fixture.tagged(manifest, as: "crafted-compressed:latest")])

        let loaded = try await fixture.load(fixture.makeCompressedTarball(compression))

        #expect(loaded == ["docker.io/library/crafted-compressed:latest"])
    }

    @Test("a sparse multi-platform index (docker save v25+) loads the present platform")
    func sparseIndexLoadsPresentPlatform() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(manifest, as: "crafted-sparse:latest"),
            fixture.tagged(fixture.manifestWithoutBlobs(arch: "amd64"), as: "crafted-sparse:latest"),
        ])

        let loaded = try await fixture.load(fixture.makeTarball())

        #expect(loaded == ["docker.io/library/crafted-sparse:latest"])
    }

    @Test("a complete flat multi-platform archive becomes one indexed tag owner")
    func completeMultiPlatformArchiveLoadsAsOneIndex() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let canonical = "docker.io/library/crafted-multi:latest"
        let arm64 = try fixture.writeImage(
            arch: "arm64",
            contents: "arm64 content\n"
        )
        let amd64 = try fixture.writeImage(
            arch: "amd64",
            contents: "amd64 content\n"
        )
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(arm64, as: "crafted-multi:latest"),
            fixture.tagged(amd64, as: "crafted-multi:latest"),
        ])

        let tarball = try fixture.makeTarball()
        let loaded = try await fixture.load(tarball)
        let store = try ImageStore(path: fixture.storeDir)
        let stored = try await store.get(
            reference: canonical
        )
        let index = try await stored.index()
        let firstRoot = stored.digest
        let reloaded = try await fixture.load(tarball)
        let secondRoot = try await store.get(reference: canonical).digest

        #expect(loaded == [canonical])
        #expect(reloaded == [canonical])
        #expect(firstRoot == secondRoot)
        #expect(Set(index.manifests.map(\.digest)) == [arm64.digest, amd64.digest])
        #expect(Set(index.manifests.compactMap(\.platform)) == [arm64.platform!, amd64.platform!])
        #expect(
            try await store.list().contains {
                $0.reference.hasPrefix("moby-dangling@")
            } == false
        )
    }

    @Test("an explicit platform load selects one variant from a complete archive")
    func explicitPlatformSelectsVariant() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let canonical = "docker.io/library/crafted-selected:latest"
        let arm64 = try fixture.writeImage(
            arch: "arm64",
            contents: "selected arm64\n"
        )
        let amd64 = try fixture.writeImage(
            arch: "amd64",
            contents: "selected amd64\n"
        )
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(arm64, as: "crafted-selected:latest"),
            fixture.tagged(amd64, as: "crafted-selected:latest"),
        ])

        _ = try await fixture.load(
            fixture.makeTarball(),
            platform: Platform(arch: "arm64", os: "linux")
        )
        let stored = try await ImageStore(path: fixture.storeDir).get(
            reference: canonical
        )

        #expect(try await stored.index().manifests.map(\.digest) == [arm64.digest])
    }

    @Test("a top-level BuildKit attestation remains attached to its runnable manifest")
    func topLevelAttestationLoadsWithImage() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let canonical = "docker.io/library/crafted-attested:latest"
        let image = try fixture.writeImage()
        let attestation = try fixture.writeAttestation(for: image)
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(image, as: "crafted-attested:latest"),
            fixture.tagged(attestation, as: "crafted-attested:latest"),
        ])

        let loaded = try await fixture.load(fixture.makeTarball())
        let stored = try await ImageStore(path: fixture.storeDir).get(
            reference: canonical
        )

        #expect(loaded == [canonical])
        #expect(
            Set(try await stored.index().manifests.map(\.digest))
                == [image.digest, attestation.digest]
        )
    }

    @Test("an attestation-only tag is not exposed as a runnable Docker image")
    func attestationOnlyTagIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let subject = try fixture.writeImage()
        let attestation = try fixture.writeAttestation(for: subject)
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(attestation, as: "crafted-artifact-only:latest")
        ])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("an untagged artifact-only root is not imported as a Docker image")
    func untaggedArtifactOnlyRootIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let subject = try fixture.writeImage()
        let artifact = try fixture.writeSubjectArtifact(for: subject)
        try fixture.writeTopIndex(manifests: [artifact])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("a platformless manifest is not treated as a runnable Docker root")
    func platformlessManifestIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let image = try fixture.writeImage()
        let platformless = Descriptor(
            mediaType: image.mediaType,
            digest: image.digest,
            size: image.size,
            annotations: image.annotations
        )
        try fixture.writeTopIndex(manifests: [platformless])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("OCI subject artifacts remain attached only to the selected platform")
    func subjectArtifactsFollowSelectedPlatform() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let canonical = "docker.io/library/crafted-subject:latest"
        let arm64 = try fixture.writeImage(
            arch: "arm64",
            contents: "subject arm64\n"
        )
        let amd64 = try fixture.writeImage(
            arch: "amd64",
            contents: "subject amd64\n"
        )
        let arm64Artifact = try fixture.writeSubjectArtifact(for: arm64)
        let amd64Artifact = try fixture.writeSubjectArtifact(for: amd64)
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(arm64Artifact, as: "crafted-subject:latest"),
            fixture.tagged(amd64, as: "crafted-subject:latest"),
            fixture.tagged(amd64Artifact, as: "crafted-subject:latest"),
            fixture.tagged(arm64, as: "crafted-subject:latest"),
        ])

        let loaded = try await fixture.load(
            fixture.makeTarball(),
            platform: Platform(arch: "arm64", os: "linux")
        )
        let stored = try await ImageStore(path: fixture.storeDir).get(
            reference: canonical
        )

        #expect(loaded == [canonical])
        #expect(
            try await stored.index().manifests.first?.digest
                == arm64.digest
        )
        #expect(
            Set(try await stored.index().manifests.map(\.digest))
                == [arm64.digest, arm64Artifact.digest]
        )
    }

    @Test("an OCI subject-artifact-only tag is not exposed as an image")
    func subjectArtifactOnlyTagIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let subject = try fixture.writeImage()
        let artifact = try fixture.writeSubjectArtifact(for: subject)
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(artifact, as: "crafted-subject-only:latest")
        ])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("a nested artifact-first index is canonicalized runnable-first")
    func nestedArtifactFirstIndexIsCanonicalized() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let canonical = "docker.io/library/crafted-nested-subject:latest"
        let image = try fixture.writeImage()
        let artifact = try fixture.writeSubjectArtifact(for: image)
        let nested = try fixture.nestedIndex(of: [artifact, image])
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(
                nested,
                as: "crafted-nested-subject:latest"
            )
        ])

        _ = try await fixture.load(
            fixture.makeTarball(),
            platform: Platform(arch: "arm64", os: "linux")
        )
        let stored = try await ImageStore(path: fixture.storeDir).get(
            reference: canonical
        )

        #expect(
            try await stored.index().manifests.map(\.digest)
                == [image.digest, artifact.digest]
        )
    }

    @Test("a nested index containing only artifacts is rejected")
    func nestedArtifactOnlyIndexIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let subject = try fixture.writeImage()
        let artifact = try fixture.writeSubjectArtifact(for: subject)
        let nested = try fixture.nestedIndex(of: [artifact])
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(
                nested,
                as: "crafted-nested-artifact-only:latest"
            )
        ])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("nested artifacts must name a runnable subject in the same image graph")
    func nestedOrphanArtifactIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let runnable = try fixture.writeImage(contents: "kept image\n")
        let outsideSubject = try fixture.writeImage(
            contents: "outside subject\n"
        )
        let orphan = try fixture.writeSubjectArtifact(for: outsideSubject)
        let nested = try fixture.nestedIndex(of: [runnable, orphan])
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(nested, as: "crafted-orphan-artifact:latest")
        ])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("a BuildKit marker on an index document makes that root an artifact")
    func documentAnnotatedArtifactIndexIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let runnable = try fixture.writeImage()
        let artifactIndex = try fixture.nestedIndex(
            of: [runnable],
            annotations: [
                "vnd.docker.reference.type": " Attestation-Manifest ",
                "vnd.docker.reference.digest": runnable.digest,
            ]
        )
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(
                artifactIndex,
                as: "crafted-document-artifact:latest"
            )
        ])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("two different roots for one platform and tag remain a conflict")
    func competingSamePlatformRootsAreRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.writeImage(contents: "first root\n")
        let second = try fixture.writeImage(contents: "second root\n")
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(first, as: "crafted-conflict:latest"),
            fixture.tagged(second, as: "crafted-conflict:latest"),
        ])

        await #expect(throws: ClientImageError.self) {
            try await fixture.load(fixture.makeTarball())
        }
    }

    @Test("a nested sparse index, the exact shape of docker save v25+, loads the present platform")
    func nestedSparseIndexLoadsPresentPlatform() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        let nested = try fixture.nestedIndex(of: [manifest, fixture.manifestWithoutBlobs(arch: "amd64")])
        try fixture.writeTopIndex(manifests: [fixture.tagged(nested, as: "crafted-nested:latest")])

        let loaded = try await fixture.load(fixture.makeTarball())

        #expect(loaded == ["docker.io/library/crafted-nested:latest"])
    }

    @Test("a tarball with no loadable manifest is rejected")
    func tarballWithNoLoadableManifestIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        try fixture.writeTopIndex(manifests: [fixture.tagged(fixture.manifestWithoutBlobs(arch: "arm64"), as: "crafted-hollow:latest")])
        let tarball = try fixture.makeTarball()

        await #expect(throws: OCILayoutPruner.PruneError.nothingLoadable) {
            try await fixture.load(tarball)
        }
    }

    @Test("a legacy docker-archive tarball with an empty manifest list is rejected")
    func legacyEmptyManifestTarballIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let tarball = try fixture.makeLegacyTarballWithEmptyManifest()

        await #expect(throws: OCILayoutPruner.PruneError.nothingLoadable) {
            try await fixture.load(tarball)
        }
    }

    @Test("a multi-tag save sharing one manifest blob loads every tag, even when its blobs are already in the store")
    func multiTagSaveLoadsEveryTag() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(manifest, as: "crafted-one:latest"),
            fixture.tagged(manifest, as: "crafted-two:latest"),
        ])

        let tarball = try fixture.makeTarball()
        let loaded = try await fixture.load(tarball)
        let reloaded = try await fixture.load(tarball)

        let bothTags = [
            "docker.io/library/crafted-one:latest",
            "docker.io/library/crafted-two:latest",
        ]
        #expect(loaded == bothTags)
        #expect(reloaded == bothTags)
    }

    @Test("per-descriptor import archives are released before the next import")
    func descriptorArchivesHaveBoundedLifetime() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(manifest, as: "crafted-lifetime-one:latest"),
            fixture.tagged(manifest, as: "crafted-lifetime-two:latest"),
        ])
        let localStore = try LocalImageArchiveStore(path: fixture.storeDir)
        let probe = DescriptorArchiveLifetimeProbe(delegate: localStore)
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: localStore,
            archiveLoader: probe
        )

        let loaded = try await service.load(
            tarballPath: fixture.makeTarball(),
            platform: nil,
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )
        let observations = await probe.observations()

        #expect(
            loaded == [
                "docker.io/library/crafted-lifetime-one:latest",
                "docker.io/library/crafted-lifetime-two:latest",
            ]
        )
        #expect(observations.callCount == 2)
        #expect(observations.everyArchivePresentDuringImport)
        #expect(!observations.previousArchiveSurvivedToNextImport)
    }

    @Test("a deleted image loads again from the same tarball")
    func deletedImageLoadsAgain() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(manifest, as: "crafted-one:latest"),
            fixture.tagged(manifest, as: "crafted-two:latest"),
        ])
        let tarball = try fixture.makeTarball()
        _ = try await fixture.load(tarball)

        let store = try ImageStore(path: fixture.storeDir)
        try await store.delete(reference: "docker.io/library/crafted-one:latest", performCleanup: true)
        try await store.delete(reference: "docker.io/library/crafted-two:latest", performCleanup: true)

        let reloaded = try await fixture.load(tarball)

        #expect(
            reloaded == [
                "docker.io/library/crafted-one:latest",
                "docker.io/library/crafted-two:latest",
            ])
    }

    @Test("a saved image loads back into an empty store")
    func savedImageLoadsBackIntoEmptyStore() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [fixture.tagged(manifest, as: "crafted-roundtrip:latest")])
        _ = try await fixture.load(fixture.makeTarball())

        let saved = try await fixture.saveTarball(references: ["docker.io/library/crafted-roundtrip:latest"])

        let reloaded = try await fixture.loadIntoEmptyStore(saved)

        #expect(reloaded == ["docker.io/library/crafted-roundtrip:latest"])
    }

    @Test("a multi-tag save loads back into an empty store with every tag")
    func multiTagSaveLoadsBackIntoEmptyStore() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(manifest, as: "crafted-one:latest"),
            fixture.tagged(manifest, as: "crafted-two:latest"),
        ])
        _ = try await fixture.load(fixture.makeTarball())

        let saved = try await fixture.saveTarball(
            references: [
                "docker.io/library/crafted-one:latest",
                "docker.io/library/crafted-two:latest",
            ])

        let reloaded = try await fixture.loadIntoEmptyStore(saved)

        #expect(
            reloaded == [
                "docker.io/library/crafted-one:latest",
                "docker.io/library/crafted-two:latest",
            ])
    }

    @Test("an attested multi-platform image saves and reloads with every runnable platform")
    func attestedMultiPlatformSaveLoadRoundTrip() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let familiar = "crafted-attested-multi:latest"
        let canonical = "docker.io/library/\(familiar)"
        let arm64 = try fixture.writeImage(
            arch: "arm64",
            contents: "attested arm64\n"
        )
        let amd64 = try fixture.writeImage(
            arch: "amd64",
            contents: "attested amd64\n"
        )
        let arm64Attestation = try fixture.writeAttestation(for: arm64)
        let amd64Attestation = try fixture.writeAttestation(for: amd64)
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(arm64, as: familiar),
            fixture.tagged(arm64Attestation, as: familiar),
            fixture.tagged(amd64, as: familiar),
            fixture.tagged(amd64Attestation, as: familiar),
        ])

        _ = try await fixture.load(fixture.makeTarball())
        let saved = try await fixture.saveTarball(references: [canonical])
        let archiveManifests = try fixture.dockerManifests(in: saved)
        let roundTrip = try await fixture.loadIntoNewStore(saved)
        let roundTripStore = try ImageStore(path: roundTrip.storeDir)
        let stored = try await roundTripStore.get(reference: canonical)
        let firstRoot = stored.digest
        let storedManifests = try await stored.index().manifests
        var storedLayerMediaTypes: [String] = []
        for descriptor in storedManifests {
            guard let platform = descriptor.platform else { continue }
            storedLayerMediaTypes.append(
                contentsOf: try await stored.manifest(for: platform).layers.map(
                    \.mediaType
                )
            )
        }
        let reloaded = try await fixture.loadIntoStore(
            saved,
            storeDir: roundTrip.storeDir
        )
        let secondRoot = try await roundTripStore.get(reference: canonical).digest

        #expect(archiveManifests.count == 2)
        #expect(
            archiveManifests.allSatisfy {
                $0.repoTags == [canonical]
            }
        )
        #expect(roundTrip.loaded == [canonical])
        #expect(reloaded == [canonical])
        #expect(firstRoot == secondRoot)
        #expect(storedManifests.count == 2)
        #expect(
            Set(storedManifests.compactMap(\.platform))
                == [arm64.platform!, amd64.platform!]
        )
        #expect(Set(storedLayerMediaTypes) == [MediaTypes.imageLayer])
        #expect(
            storedManifests.contains {
                $0.annotations?["vnd.docker.reference.type"]
                    == "attestation-manifest"
            } == false
        )
    }

    @Test("exact same-platform tags save and reload with their distinct config identities")
    func exactSamePlatformTagsSaveLoadRoundTrip() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.writeImage(contents: "first exact image\n")
        let second = try fixture.writeImage(contents: "second exact image\n")
        let root = try fixture.nestedIndex(of: [first, second])
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(root, as: "crafted-exact-base:latest")
        ])
        _ = try await ImageStore(path: fixture.storeDir).load(
            from: fixture.layoutDir
        )
        let service = try fixture.localService()
        _ = try await service.tag(
            source: first.digest,
            target: "crafted-exact:first"
        )
        _ = try await service.tag(
            source: second.digest,
            target: "crafted-exact:second"
        )
        let firstConfig = try fixture.configDigest(for: first)
        let secondConfig = try fixture.configDigest(for: second)

        let saved = try await service.saveWithIdentities(
            references: [
                "docker.io/library/crafted-exact:first",
                "docker.io/library/crafted-exact:second",
            ],
            platform: nil,
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )
        defer { try? FileManager.default.removeItem(at: saved.url.deletingLastPathComponent()) }
        let roundTrip = try await fixture.loadIntoNewStore(saved.url)
        let roundTripStore = try ImageStore(path: roundTrip.storeDir)
        let platform = Platform(arch: "arm64", os: "linux")

        #expect(saved.actorIDs == [firstConfig, secondConfig])
        #expect(
            try await roundTripStore.get(
                reference: "docker.io/library/crafted-exact:first"
            ).manifest(for: platform).config.digest == firstConfig
        )
        #expect(
            try await roundTripStore.get(
                reference: "docker.io/library/crafted-exact:second"
            ).manifest(for: platform).config.digest == secondConfig
        )
    }

    @Test("an exact nested-index tag saves and reloads its selected config")
    func exactNestedIndexSaveLoadRoundTrip() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let selected = try fixture.writeImage(contents: "nested exact image\n")
        let nested = try fixture.nestedIndex(of: [selected])
        let root = try fixture.nestedIndex(of: [nested])
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(root, as: "crafted-nested-exact:base")
        ])
        _ = try await ImageStore(path: fixture.storeDir).load(
            from: fixture.layoutDir
        )
        let service = try fixture.localService()
        let canonical = "docker.io/library/crafted-nested-exact:selected"
        _ = try await service.tag(source: nested.digest, target: canonical)
        let selectedConfig = try fixture.configDigest(for: selected)

        let saved = try await service.saveWithIdentities(
            references: [canonical],
            platform: nil,
            appleContainerAppSupportUrl: fixture.storeDir,
            logger: fixture.logger
        )
        defer { try? FileManager.default.removeItem(at: saved.url.deletingLastPathComponent()) }
        let archiveManifests = try fixture.dockerManifests(in: saved.url)
        let roundTrip = try await fixture.loadIntoNewStore(saved.url)
        let reloaded = try await ImageStore(path: roundTrip.storeDir).get(
            reference: canonical
        )

        // Docker's legacy archive format has no nested-index representation;
        // the immutable nested digest is intentionally flattened, while the
        // selected runnable config identity and bytes remain exact.
        #expect(archiveManifests.count == 1)
        #expect(saved.actorIDs == [selectedConfig])
        #expect(
            try await reloaded.manifest(
                for: Platform(arch: "arm64", os: "linux")
            ).config.digest == selectedConfig
        )
    }

    @Test("shared nested index DAGs export each runnable manifest once")
    func sharedIndexDAGIsDeduplicated() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        var root = try fixture.writeImage()
        for _ in 0..<24 {
            root = try fixture.nestedIndex(of: [root, root])
        }
        try fixture.writeTopIndex(manifests: [root])

        let manifests = try await fixture.convertToDockerArchive(
            resolvedReferences: ["docker.io/library/crafted-dag:latest"]
        )

        #expect(manifests.count == 1)
        #expect(
            manifests[0].repoTags
                == ["docker.io/library/crafted-dag:latest"]
        )
    }

    @Test("descriptor and document artifact indexes are omitted from docker-archive")
    func artifactIndexesAreOmitted() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let runnable = try fixture.writeImage()
        let descriptorArtifact = try fixture.nestedIndex(
            of: [runnable],
            descriptorArtifactType: "application/vnd.example.attestation"
        )
        let documentArtifact = try fixture.nestedIndex(
            of: [runnable],
            artifactType: "application/vnd.example.attestation",
            subject: runnable
        )
        try fixture.writeTopIndex(manifests: [
            runnable,
            descriptorArtifact,
            documentArtifact,
        ])

        let manifests = try await fixture.convertToDockerArchive(
            resolvedReferences: [
                "docker.io/library/crafted-artifact-index:latest",
                "docker.io/library/crafted-artifact-index:latest",
                "docker.io/library/crafted-artifact-index:latest",
            ]
        )

        #expect(manifests.count == 1)
    }

    @Test("bare content digests are never emitted as docker RepoTags")
    func bareDigestIsNotARepoTag() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let runnable = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [runnable])

        let manifests = try await fixture.convertToDockerArchive(
            resolvedReferences: ["sha256:" + String(repeating: "a", count: 64)]
        )

        #expect(manifests.count == 1)
        #expect(manifests[0].repoTags == [])
    }

    @Test("invalid content digests cannot escape the OCI blob directory")
    func invalidContentDigestIsRejected() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        try fixture.writeTopIndex(manifests: [
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: "../../..:/etc/passwd",
                size: 1
            )
        ])

        await #expect(throws: ContainerImageUtility.Error.self) {
            try await fixture.convertToDockerArchive(
                resolvedReferences: [
                    "docker.io/library/crafted-invalid-digest:latest"
                ]
            )
        }
    }

    @Test("saving an internal dangling owner never exports it as a RepoTag")
    func internalDanglingReferenceIsNotARepoTag() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let canonical = "docker.io/library/crafted-hidden-save:latest"
        let manifest = try fixture.writeImage()
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(manifest, as: "crafted-hidden-save:latest")
        ])
        _ = try await fixture.load(fixture.makeTarball())

        let store = try ImageStore(path: fixture.storeDir)
        let root = try await store.get(reference: canonical).digest
        let hidden = "moby-dangling@\(root)"
        _ = try await store.tag(existing: canonical, new: hidden)
        let saved = try await fixture.saveTarball(references: [hidden])
        let archiveManifests = try fixture.dockerManifests(in: saved)

        #expect(archiveManifests.count == 1)
        #expect(archiveManifests[0].repoTags == [])
        #expect(
            archiveManifests.flatMap { $0.repoTags ?? [] }.contains(hidden)
                == false
        )
    }

    @Test("loading changed content replaces a familiar key with one canonical owner")
    func changedContentReplacesFamiliarOwner() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }
        let familiar = "crafted-replacement:latest"
        let canonical = "docker.io/library/crafted-replacement:latest"

        let oldManifest = try fixture.writeImage(contents: "old content\n")
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(oldManifest, as: familiar)
        ])
        let firstTarball = try fixture.makeTarball()
        _ = try await fixture.load(firstTarball)

        let store = try ImageStore(path: fixture.storeDir)
        let oldRoot = try await store.get(reference: canonical).digest
        _ = try await store.tag(existing: canonical, new: familiar)
        try await store.delete(reference: canonical)
        try FileManager.default.removeItem(at: firstTarball)

        let newManifest = try fixture.writeImage(contents: "new content\n")
        try fixture.writeTopIndex(manifests: [
            fixture.tagged(newManifest, as: familiar)
        ])
        let loaded = try await fixture.load(fixture.makeTarball())

        let images = try await store.list()
        let current = try await store.get(reference: canonical)
        #expect(loaded == [canonical])
        #expect(current.digest != oldRoot)
        #expect(!images.contains { $0.reference == familiar })
        #expect(
            images.contains {
                $0.reference == "moby-dangling@\(oldRoot)"
                    && $0.digest == oldRoot
            }
        )
    }

}

private actor DescriptorArchiveLifetimeProbe: ImageArchiveLoading {
    private let delegate: LocalImageArchiveStore
    private var previousArchive: URL?
    private var callCount = 0
    private var everyArchivePresentDuringImport = true
    private var previousArchiveSurvivedToNextImport = false

    init(delegate: LocalImageArchiveStore) {
        self.delegate = delegate
    }

    func load(
        ociLayoutPath: URL,
        archivePath: URL
    ) async throws -> ImageArchiveLoadResult {
        if let previousArchive,
            FileManager.default.fileExists(atPath: previousArchive.path)
        {
            previousArchiveSurvivedToNextImport = true
        }
        previousArchive = archivePath
        callCount += 1
        everyArchivePresentDuringImport =
            everyArchivePresentDuringImport
            && FileManager.default.fileExists(atPath: archivePath.path)
        return try await delegate.load(
            ociLayoutPath: ociLayoutPath,
            archivePath: archivePath
        )
    }

    func observations() -> (
        callCount: Int,
        everyArchivePresentDuringImport: Bool,
        previousArchiveSurvivedToNextImport: Bool
    ) {
        (
            callCount,
            everyArchivePresentDuringImport,
            previousArchiveSurvivedToNextImport
        )
    }
}

private struct LocalLayoutIdentityCatalog: ImageIdentityCatalog {
    let store: LocalImageArchiveStore
    let blobsDirectory: URL

    func list() async throws -> [ClientImage] {
        try await store.list()
    }

    func index(for image: ClientImage) async throws -> Index {
        guard let index = try await index(digest: image.digest) else {
            throw ClientImageError.notFound(id: image.digest)
        }
        return index
    }

    func index(digest: String) async throws -> Index? {
        try decode(Index.self, digest: digest)
    }

    func manifest(digest: String) async throws -> Manifest? {
        try decode(Manifest.self, digest: digest)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        digest: String
    ) throws -> Value? {
        let path = blobsDirectory.appendingPathComponent(
            String(digest.dropFirst("sha256:".count))
        )
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: Data(contentsOf: path))
    }
}

private struct ImageTarballFixture {
    let workDir: URL
    let layoutDir: URL
    let storeDir: URL
    let logger = Logger(label: "test")

    init() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("image-load-\(UUID().uuidString)")
        layoutDir = workDir.appendingPathComponent("layout")
        storeDir = workDir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: layoutDir.appendingPathComponent("blobs/sha256"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8).write(to: layoutDir.appendingPathComponent("oci-layout"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workDir)
    }

    func localService() throws -> ClientImageService {
        let store = try LocalImageArchiveStore(path: storeDir)
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: LocalLayoutIdentityCatalog(
                store: store,
                blobsDirectory: layoutDir.appendingPathComponent("blobs/sha256")
            ),
            appSupportURL: workDir.appendingPathComponent("resolver-state"),
            mutationCoordinator: coordinator
        )
        return ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            archiveLoader: store
        )
    }

    func configDigest(for descriptor: Descriptor) throws -> String {
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: blobURL(for: descriptor.digest))
        )
        return manifest.config.digest
    }

    private func blobURL(for digest: String) -> URL {
        layoutDir.appendingPathComponent("blobs/sha256").appendingPathComponent(
            String(digest.dropFirst("sha256:".count))
        )
    }

    func writeImage(
        arch: String = "arm64",
        contents: String = "hello from crafted image\n"
    ) throws -> Descriptor {
        let layer = try writeLayerBlob(contents: contents)
        let config = try writeBlob(
            Data(#"{"architecture":"\#(arch)","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":["\#(layer.digest)"]}}"#.utf8))
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: config.digest, size: config.size),
            layers: [Descriptor(mediaType: MediaTypes.imageLayer, digest: layer.digest, size: layer.size)]
        )
        let written = try writeBlob(JSONEncoder().encode(manifest))
        return Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: written.digest,
            size: written.size,
            platform: Platform(arch: arch, os: "linux")
        )
    }

    func writeAttestation(for subject: Descriptor) throws -> Descriptor {
        let config = try writeBlob(
            Data(#"{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":[]}}"#.utf8)
        )
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: config.digest,
                size: config.size
            ),
            layers: []
        )
        let written = try writeBlob(JSONEncoder().encode(manifest))
        return Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: written.digest,
            size: written.size,
            annotations: [
                "vnd.docker.reference.type": "attestation-manifest",
                "vnd.docker.reference.digest": subject.digest,
            ],
            platform: Platform(arch: "unknown", os: "unknown")
        )
    }

    func writeSubjectArtifact(for subject: Descriptor) throws -> Descriptor {
        let config = try writeBlob(
            Data(
                #"{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":[]}}"#.utf8
            )
        )
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: config.digest,
                size: config.size
            ),
            layers: [],
            subject: subject,
            artifactType: "application/vnd.example.provenance"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let written = try writeBlob(encoder.encode(manifest))
        return Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: written.digest,
            size: written.size,
            platform: subject.platform
        )
    }

    func tagged(_ descriptor: Descriptor, as reference: String) -> Descriptor {
        var annotations = descriptor.annotations ?? [:]
        annotations["io.containerd.image.name"] = "docker.io/library/\(reference)"
        annotations["org.opencontainers.image.ref.name"] = reference
        return Descriptor(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            urls: descriptor.urls,
            annotations: annotations,
            platform: descriptor.platform,
            artifactType: descriptor.artifactType
        )
    }

    func manifestWithoutBlobs(arch: String) -> Descriptor {
        Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: "sha256:" + String(repeating: "a", count: 64),
            size: 500,
            platform: Platform(arch: arch, os: "linux")
        )
    }

    func nestedIndex(
        of manifests: [Descriptor],
        artifactType: String? = nil,
        subject: Descriptor? = nil,
        descriptorArtifactType: String? = nil,
        annotations: [String: String]? = nil
    ) throws -> Descriptor {
        let written = try writeBlob(
            JSONEncoder().encode(
                Index(
                    manifests: manifests,
                    annotations: annotations,
                    subject: subject,
                    artifactType: artifactType
                )
            )
        )
        return Descriptor(
            mediaType: MediaTypes.index,
            digest: written.digest,
            size: written.size,
            artifactType: descriptorArtifactType
        )
    }

    func writeTopIndex(manifests: [Descriptor]) throws {
        try JSONEncoder().encode(Index(manifests: manifests)).write(to: layoutDir.appendingPathComponent("index.json"))
    }

    func makeTarball() throws -> URL {
        let tarball = workDir.appendingPathComponent("image.tar")
        try ArchiveUtility.create(tarPath: tarball, from: layoutDir)
        return tarball
    }

    func makeCompressedTarball(_ compression: Filter) throws -> URL {
        let tarball = workDir.appendingPathComponent("image.tar.\(compression.rawValue)")
        if compression == .zstd {
            let plainTarball = try makeTarball()
            try ZstdTestSupport.compress(
                source: plainTarball,
                destination: tarball
            )
            return tarball
        }
        let writer = try ArchiveWriter(format: .paxRestricted, filter: compression, file: tarball)
        try writer.archiveDirectory(layoutDir)
        try writer.finishEncoding()
        return tarball
    }

    func makeLegacyTarballWithEmptyManifest() throws -> URL {
        let legacyDir = workDir.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacyDir.appendingPathComponent("manifest.json"))
        let tarball = workDir.appendingPathComponent("legacy.tar")
        try ArchiveUtility.create(tarPath: tarball, from: legacyDir)
        return tarball
    }

    func load(
        _ tarball: URL,
        platform: Platform? = nil
    ) async throws -> [String] {
        try await load(tarball, into: storeDir, platform: platform)
    }

    func loadIntoEmptyStore(_ tarball: URL) async throws -> [String] {
        try await loadIntoNewStore(tarball).loaded
    }

    func loadIntoNewStore(
        _ tarball: URL
    ) async throws -> (loaded: [String], storeDir: URL) {
        let destination = workDir.appendingPathComponent(
            "store-\(UUID().uuidString)"
        )
        return try await (
            load(
                tarball,
                into: destination,
                platform: nil
            ),
            destination
        )
    }

    func loadIntoStore(
        _ tarball: URL,
        storeDir: URL
    ) async throws -> [String] {
        try await load(
            tarball,
            into: storeDir,
            platform: nil
        )
    }

    func dockerManifests(in tarball: URL) throws -> [TarManifest] {
        let extracted = workDir.appendingPathComponent(
            "saved-extracted-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: extracted,
            withIntermediateDirectories: true
        )
        try ArchiveUtility.extract(tarPath: tarball, to: extracted)
        return try JSONDecoder().decode(
            [TarManifest].self,
            from: Data(
                contentsOf: extracted.appendingPathComponent("manifest.json")
            )
        )
    }

    func convertToDockerArchive(
        resolvedReferences: [String]
    ) async throws -> [TarManifest] {
        let dockerFormat = workDir.appendingPathComponent(
            "converted-docker-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: dockerFormat,
            withIntermediateDirectories: true
        )
        let manifests = try await ContainerImageUtility.convertOCIToDockerTar(
            ociLayoutPath: layoutDir,
            dockerFormatPath: dockerFormat,
            resolvedRefs: resolvedReferences,
            logger: logger
        )
        return try JSONDecoder().decode(
            [TarManifest].self,
            from: JSONSerialization.data(
                withJSONObject: manifests,
                options: [.sortedKeys]
            )
        )
    }

    func saveTarball(references: [String]) async throws -> URL {
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig()
        )
        let saved = try await service.exportTarball(
            resolvedReferences: references,
            platform: nil,
            appleContainerAppSupportUrl: storeDir,
            logger: logger
        )
        let kept = workDir.appendingPathComponent("saved-\(UUID().uuidString).tar")
        try FileManager.default.moveItem(at: saved, to: kept)
        return kept
    }

    private func load(
        _ tarball: URL,
        into store: URL,
        platform: Platform?
    ) async throws -> [String] {
        let localStore = try LocalImageArchiveStore(path: store)
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: localStore,
            archiveLoader: localStore
        )
        return try await service.load(
            tarballPath: tarball,
            platform: platform,
            appleContainerAppSupportUrl: store,
            logger: logger
        )
    }

    private func writeLayerBlob(
        contents: String
    ) throws -> (digest: String, size: Int64) {
        let rootfs = workDir.appendingPathComponent("rootfs")
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)
        try Data(contents.utf8).write(
            to: rootfs.appendingPathComponent("hello.txt")
        )
        let layerTar = workDir.appendingPathComponent("layer.tar")
        try? FileManager.default.removeItem(at: layerTar)
        try ArchiveUtility.create(tarPath: layerTar, from: rootfs)
        return try writeBlob(Data(contentsOf: layerTar))
    }

    private func writeBlob(_ data: Data) throws -> (digest: String, size: Int64) {
        let digest = "sha256:" + data.sha256Hex()
        try data.write(to: layoutDir.appendingPathComponent("blobs/sha256/\(digest.dropFirst("sha256:".count))"))
        return (digest, Int64(data.count))
    }
}
