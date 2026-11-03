import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import socktainer

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

    @Test("a compressed tarball loads", arguments: [Filter.gzip])
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

    @Test("a pulled multi-platform image, holding only its own platform's blobs, saves and loads back")
    func pulledMultiPlatformImageSavesPresentPlatform() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let present = try fixture.writeImage()
        let index = try fixture.nestedIndex(of: [present, fixture.manifestWithoutBlobs(arch: "amd64")])
        let reference = "docker.io/library/crafted-pulled:latest"
        try await fixture.storeAsPulled(index, reference: reference)

        let saved = try await fixture.saveTarball(references: [reference])
        let reloaded = try await fixture.loadIntoEmptyStore(saved)

        #expect(reloaded == [reference])
    }

    @Test("an OCI layout written for a pulled image lists only the complete platform, store untouched")
    func savedLayoutKeepsOnlyCompletePlatform() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let present = try fixture.writeImage()
        let index = try fixture.nestedIndex(of: [present, fixture.manifestWithoutBlobs(arch: "amd64")])
        let reference = "docker.io/library/crafted-layout:latest"
        try await fixture.storeAsPulled(index, reference: reference)
        let storeBlobsBefore = try fixture.storeBlobNames()

        let out = fixture.workDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await ClientImageService.writeOCILayout(
            references: [reference],
            imageStore: ImageStore(path: fixture.storeDir),
            contentRoot: fixture.storeDir.appendingPathComponent("content"),
            to: out,
            platform: nil,
            logger: fixture.logger
        )

        let top = try JSONDecoder().decode(Index.self, from: Data(contentsOf: out.appendingPathComponent("index.json")))
        let saved = try #require(top.manifests.first)
        #expect(top.manifests.count == 1)
        #expect(saved.annotations?["io.containerd.image.name"] == reference)
        let savedIndex = try JSONDecoder().decode(
            Index.self, from: Data(contentsOf: out.appendingPathComponent("blobs/sha256/\(saved.digest.dropFirst(7))")))
        #expect(savedIndex.manifests.map(\.digest) == [present.digest])
        #expect(try fixture.storeBlobNames() == storeBlobsBefore)
    }

    @Test("a save of an image with several complete platforms tags only the host's in the docker-archive manifest")
    func multiPlatformSaveTagsOnePlatform() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let amd64 = try fixture.writeImage(arch: "amd64")
        let arm64 = try fixture.writeImage(arch: "arm64")
        let index = try fixture.nestedIndex(of: [amd64, arm64])
        let reference = "docker.io/library/crafted-multi:latest"
        try await fixture.storeAsPulled(index, reference: reference)

        let saved = try await fixture.saveTarball(references: [reference])
        let extracted = fixture.workDir.appendingPathComponent("extracted-multi")
        try ArchiveUtility.extract(tarPath: saved, to: extracted, logger: fixture.logger)

        let manifests = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: extracted.appendingPathComponent("manifest.json"))) as? [[String: Any]])
        #expect(manifests.count == 1)
        let configName = try #require(manifests.first?["Config"] as? String)
        let config = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: extracted.appendingPathComponent(configName))) as? [String: Any])
        #expect(config["architecture"] as? String == Platform.current.architecture)
    }

    @Test("a save never tags an attestation manifest, so a load keeps the runnable platform")
    func saveSkipsAttestationManifest() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let image = try fixture.writeImage(arch: Platform.current.architecture)
        let index = try fixture.nestedIndex(of: [image, fixture.writeAttestation(for: image)])
        let reference = "docker.io/library/crafted-attested:latest"
        try await fixture.storeAsPulled(index, reference: reference)

        let saved = try await fixture.saveTarball(references: [reference])
        let extracted = fixture.workDir.appendingPathComponent("extracted-attested")
        try ArchiveUtility.extract(tarPath: saved, to: extracted, logger: fixture.logger)

        let manifests = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: extracted.appendingPathComponent("manifest.json"))) as? [[String: Any]])
        #expect(manifests.count == 1)
        let configName = try #require(manifests.first?["Config"] as? String)
        let config = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: extracted.appendingPathComponent(configName))) as? [String: Any])
        #expect(config["architecture"] as? String == Platform.current.architecture)
        #expect(config["os"] as? String == "linux")
        #expect(try await fixture.loadIntoEmptyStore(saved) == [reference])
    }

    @Test("saving a platform the image has no content for is reported as not found")
    func savingAbsentPlatformIsNotFound() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let present = try fixture.writeImage()
        let index = try fixture.nestedIndex(of: [present, fixture.manifestWithoutBlobs(arch: "amd64")])
        let reference = "docker.io/library/crafted-absent:latest"
        try await fixture.storeAsPulled(index, reference: reference)

        await #expect(throws: ClientImageError.self) {
            _ = try await fixture.saveTarball(references: [reference], platform: Platform(arch: "amd64", os: "linux"))
        }
    }

}

/// `retagForPush` (used by both `podman push <image> <destination>` and `podman manifest
/// push`) resolves the source image via `ClientImage.get`, which — like `_search` generally —
/// always reads through the real system's `container-apiserver` daemon over XPC rather than
/// any locally-injected storage path, so the specific bare-tag-vs-normalized-reference
/// regression this fixed (verified live against a real running server and a real registry —
/// see the commit this test accompanies) isn't reproducible against an isolated local
/// fixture the way the rest of this file's `ImageStore(path:)`-based tests are. This at
/// least covers the error-mapping half: a genuinely missing source image must surface as
/// `ClientImageError.notFound`, not an uncaught `ContainerizationError` from the underlying
/// `ImageStore.tag` call.
@Suite("ClientManifestService.retagForPush")
struct ClientManifestServiceRetagTests {
    @Test("A nonexistent source image is reported as not found, not a raw ImageStore error")
    func nonexistentSourceIsNotFound() async throws {
        let fixture = try ImageTarballFixture()
        defer { fixture.cleanUp() }

        let missingReference = "does-not-exist-\(UUID().uuidString.lowercased()):latest"
        let manifestClient = ClientManifestService(appSupportURL: fixture.storeDir, containerSystemConfig: ContainerSystemConfig())
        do {
            _ = try await manifestClient.retagForPush(name: missingReference, destination: "registry.example.com/repo:latest")
            Issue.record("expected retagForPush to throw for a nonexistent source image")
        } catch ClientImageError.notFound(let id) {
            #expect(id == missingReference)
        } catch let error as ContainerizationError where error.message.hasPrefix("XPC connection error") {
            // `ClientImage.get` always reaches the real container-apiserver daemon over
            // XPC (see the suite doc comment above). A CI job that never installs/starts
            // Apple Container (e.g. formatters & tests) fails here with the XPC client's
            // connection error before the mapping under test runs — an environment gap, not
            // a regression. Report it as a known issue so the run shows the gap instead of
            // a silent pass.
            withKnownIssue("container-apiserver unreachable over XPC; notFound mapping not exercised") {
                throw error
            }
        } catch {
            Issue.record("expected ClientImageError.notFound, got: \(error)")
        }
    }
}

private struct ImageTarballFixture {
    let workDir: URL
    let layoutDir: URL
    let storeDir: URL
    let service = ClientImageService(containerSystemConfig: ContainerSystemConfig())
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

    func writeImage(arch: String = "arm64") throws -> Descriptor {
        let layer = try writeLayerBlob()
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

    /// A BuildKit provenance manifest for `image`, as Docker Hub lists next to each platform:
    /// an image manifest whose platform and config are `unknown/unknown`.
    func writeAttestation(for image: Descriptor) throws -> Descriptor {
        let statement = try writeBlob(Data(#"{"_type":"https://in-toto.io/Statement/v0.1"}"#.utf8))
        let config = try writeBlob(
            Data(#"{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["\#(statement.digest)"]}}"#.utf8))
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: config.digest, size: config.size),
            layers: [Descriptor(mediaType: "application/vnd.in-toto+json", digest: statement.digest, size: statement.size)]
        )
        let written = try writeBlob(JSONEncoder().encode(manifest))
        return Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: written.digest,
            size: written.size,
            annotations: [
                "vnd.docker.reference.digest": image.digest,
                "vnd.docker.reference.type": "attestation-manifest",
            ],
            platform: Platform(arch: "unknown", os: "unknown")
        )
    }

    func tagged(_ descriptor: Descriptor, as reference: String) -> Descriptor {
        Descriptor(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            annotations: [
                "io.containerd.image.name": "docker.io/library/\(reference)",
                "org.opencontainers.image.ref.name": reference,
            ],
            platform: descriptor.platform
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

    func nestedIndex(of manifests: [Descriptor]) throws -> Descriptor {
        let written = try writeBlob(JSONEncoder().encode(Index(manifests: manifests)))
        return Descriptor(mediaType: MediaTypes.index, digest: written.digest, size: written.size)
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

    func load(_ tarball: URL) async throws -> [String] {
        try await load(tarball, into: storeDir)
    }

    func loadIntoEmptyStore(_ tarball: URL) async throws -> [String] {
        try await load(tarball, into: workDir.appendingPathComponent("store-\(UUID().uuidString)"))
    }

    /// Puts `index` in the store exactly as a single-platform pull leaves it: the full
    /// upstream index, but only the blobs that were fetched (those written to the layout).
    func storeAsPulled(_ index: Descriptor, reference: String) async throws {
        let blobs = storeDir.appendingPathComponent("content/blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: layoutDir.appendingPathComponent("blobs/sha256").path) {
            try FileManager.default.copyItem(
                at: layoutDir.appendingPathComponent("blobs/sha256/\(name)"), to: blobs.appendingPathComponent(name))
        }
        try await ImageStore(path: storeDir).create(description: Image.Description(reference: reference, descriptor: index))
    }

    func storeBlobNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: storeDir.appendingPathComponent("content/blobs/sha256").path))
    }

    func saveTarball(references: [String], platform: Platform? = nil) async throws -> URL {
        let saved = try await service.exportTarball(
            resolvedReferences: references,
            platform: platform,
            appleContainerAppSupportUrl: storeDir,
            logger: logger
        )
        let kept = workDir.appendingPathComponent("saved-\(UUID().uuidString).tar")
        try FileManager.default.moveItem(at: saved, to: kept)
        return kept
    }

    private func load(_ tarball: URL, into store: URL) async throws -> [String] {
        try await service.load(
            tarballPath: tarball,
            platform: Platform(arch: "arm64", os: "linux"),
            appleContainerAppSupportUrl: store,
            logger: logger
        )
    }

    private func writeLayerBlob() throws -> (digest: String, size: Int64) {
        let rootfs = workDir.appendingPathComponent("rootfs")
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)
        try Data("hello from crafted image\n".utf8).write(to: rootfs.appendingPathComponent("hello.txt"))
        let layerTar = workDir.appendingPathComponent("layer.tar")
        try ArchiveUtility.create(tarPath: layerTar, from: rootfs)
        return try writeBlob(Data(contentsOf: layerTar))
    }

    private func writeBlob(_ data: Data) throws -> (digest: String, size: Int64) {
        let digest = "sha256:" + data.sha256Hex()
        try data.write(to: layoutDir.appendingPathComponent("blobs/sha256/\(digest.dropFirst("sha256:".count))"))
        return (digest, Int64(data.count))
    }
}
