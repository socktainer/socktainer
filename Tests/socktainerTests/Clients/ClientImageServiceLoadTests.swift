import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationArchive
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

    func writeImage() throws -> Descriptor {
        let layer = try writeLayerBlob()
        let config = try writeBlob(
            Data(#"{"architecture":"arm64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":["\#(layer.digest)"]}}"#.utf8))
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: config.digest, size: config.size),
            layers: [Descriptor(mediaType: MediaTypes.imageLayer, digest: layer.digest, size: layer.size)]
        )
        let written = try writeBlob(JSONEncoder().encode(manifest))
        return Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: written.digest,
            size: written.size,
            platform: Platform(arch: "arm64", os: "linux")
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

    func saveTarball(references: [String]) async throws -> URL {
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
