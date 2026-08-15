import CryptoKit
import DataCompression
import Foundation
import Logging
import Testing

@testable import GlassDock

@Suite("convertDockerTarToOCI — digest integrity")
struct ContainerImageConvertTests {

    @Test("a config whose content does not match its claimed filename digest is referenced by its real digest")
    func configDigestMismatchIsReferencedByRealDigest() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let realConfigDigest = try fixture.writeConfigWithClaimedDigest(String(repeating: "a", count: 64))
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(configDigest: String(repeating: "a", count: 64), layerDigest: layerDigest, tag: "crafted:latest")

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let configDigest = try fixture.onlyManifest().config.digest
        #expect(configDigest == "sha256:\(realConfigDigest)")
        #expect(fixture.blobExists(configDigest))
    }

    @Test("a layer whose content does not match its claimed digest is referenced by its real digest")
    func layerDigestMismatchIsReferencedByRealDigest() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        _ = try fixture.writeConfigWithClaimedDigest(String(repeating: "a", count: 64))
        let realLayerDigest = try fixture.writeLayerWithClaimedDigest(String(repeating: "b", count: 64))
        try fixture.writeManifest(configDigest: String(repeating: "a", count: 64), layerDigest: String(repeating: "b", count: 64), tag: "crafted:latest")

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let layerDigest = try fixture.onlyManifest().layers[0].digest
        #expect(layerDigest == "sha256:\(realLayerDigest)")
        #expect(fixture.blobExists(layerDigest))
    }

    @Test("two tags sharing a config with a mismatched digest both resolve to the real digest without failing")
    func sharedMismatchedConfigDedupes() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let claimed = String(repeating: "a", count: 64)
        let realConfigDigest = try fixture.writeConfigWithClaimedDigest(claimed)
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifests([
            (config: claimed, layer: layerDigest, tag: "one:latest"),
            (config: claimed, layer: layerDigest, tag: "two:latest"),
        ])

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let configDigests = try fixture.allManifests().map(\.config.digest)
        #expect(configDigests == ["sha256:\(realConfigDigest)", "sha256:\(realConfigDigest)"])
        #expect(fixture.blobExists("sha256:\(realConfigDigest)"))
        #expect(!fixture.blobExists("sha256:\(claimed)"))
    }

    @Test("a missing config hard-fails the whole docker archive")
    func missingConfigRejectsWholeArchive() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let validConfigDigest = try fixture.writeConfig()
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifests([
            (
                config: validConfigDigest,
                layer: layerDigest,
                tag: "otherwise-valid:latest"
            ),
            (
                config: String(repeating: "c", count: 64),
                layer: layerDigest,
                tag: "phantom:latest"
            ),
        ])

        try await assertConversionRejected(
            fixture,
            reasonContains: "config \(String(repeating: "c", count: 64)).json is missing"
        )
    }

    @Test("a missing layer hard-fails the whole docker archive")
    func missingLayerRejectsWholeArchive() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig()
        let missingLayerDigest = String(repeating: "d", count: 64)
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: missingLayerDigest,
            tag: "missing-layer:latest"
        )

        try await assertConversionRejected(
            fixture,
            reasonContains: "layer \(missingLayerDigest)/layer.tar is missing"
        )
    }

    @Test("rootfs diff_id count must match the docker archive layer count")
    func diffIDCountMismatchRejectsArchive() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig(diffIDs: [])
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: layerDigest,
            tag: "mismatched-layers:latest"
        )

        try await assertConversionRejected(
            fixture,
            reasonContains:
                "has 0 rootfs diff_id(s), but manifest.json lists 1 layer(s)"
        )
    }

    @Test("each layer's uncompressed digest must match its ordered rootfs diff_id")
    func layerDiffIDMismatchRejectsArchive() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let claimedDiffID = "sha256:\(String(repeating: "f", count: 64))"
        let configDigest = try fixture.writeConfig(
            diffIDs: [claimedDiffID]
        )
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: layerDigest,
            tag: "mismatched-diffid:latest"
        )

        try await assertConversionRejected(
            fixture,
            reasonContains: "expected \(claimedDiffID)"
        )
    }

    @Test("a compressed layer diff_id failure removes bounded staging")
    func compressedDiffIDMismatchCleansUpStaging() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let plainTar = Data(repeating: 0, count: 1024)
        let compressedTar = try #require(plainTar.gzip())
        let claimedDiffID = "sha256:\(String(repeating: "f", count: 64))"
        let configDigest = try fixture.writeConfig(
            diffIDs: [claimedDiffID]
        )
        let layerDigest = try fixture.writeLayer(content: compressedTar)
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: layerDigest,
            tag: "compressed-mismatch:latest"
        )

        try await assertConversionRejected(
            fixture,
            reasonContains: "expected \(claimedDiffID)"
        )
        #expect(try fixture.loadLayerStagingDirectories().isEmpty)
    }

    @Test(
        "rootfs diff_ids must be well-formed sha256 digests",
        arguments: [
            "not-a-digest",
            "sha512:\(String(repeating: "a", count: 128))",
            "sha256:\(String(repeating: "a", count: 63))",
            "sha256:\(String(repeating: "g", count: 64))",
        ]
    )
    func malformedDiffIDRejectsArchive(diffID: String) async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig(diffIDs: [diffID])
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: layerDigest,
            tag: "malformed-diffid:latest"
        )

        try await assertConversionRejected(
            fixture,
            reasonContains: "rootfs diff_id"
        )
    }

    @Test("even a zero-layer scratch config must contain rootfs")
    func missingRootFSRejectsScratchArchive() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfigWithoutRootFS()
        try fixture.writeRawManifest(
            config: "\(configDigest).json",
            layers: []
        )

        try await assertConversionRejected(
            fixture,
            reasonContains: "is missing rootfs"
        )
    }

    @Test("a zero-layer scratch config with an explicit empty rootfs is valid")
    func explicitEmptyRootFSAcceptsScratchArchive() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig(diffIDs: [])
        try fixture.writeRawManifest(
            config: "\(configDigest).json",
            layers: []
        )

        let loaded = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir,
            ociLayoutPath: fixture.ociLayoutDir,
            logger: Logger(label: "test")
        )

        #expect(loaded == ["hostile:latest"])
        #expect(try fixture.onlyManifest().layers.isEmpty)
    }

    @Test(
        "RepoTags must be valid tagged names",
        arguments: [
            "",
            "untagged-name",
            "library/Uppercase:latest",
            "digest-name@sha256:\(String(repeating: "e", count: 64))",
        ]
    )
    func invalidRepoTagRejectsArchive(repoTag: String) async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig()
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: layerDigest,
            tags: [repoTag]
        )

        try await assertConversionRejected(
            fixture,
            reasonContains: "docker-archive RepoTag"
        )
    }

    @Test("a layer larger than the streaming-hash chunk is hashed correctly across chunk boundaries")
    func largeLayerHashesAcrossChunks() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let content = Data(repeating: 0xAB, count: 2_500_000)
        let layerArchive = try fixture.makeLayerArchive(
            fileContent: content
        )
        let configDigest = try fixture.writeConfig(
            diffIDs: ["sha256:\(layerArchive.sha256Hex())"]
        )
        let layerDigest = try fixture.writeLayer(content: layerArchive)
        try fixture.writeManifest(configDigest: configDigest, layerDigest: layerDigest, tag: "big:latest")

        _ = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir, ociLayoutPath: fixture.ociLayoutDir, logger: Logger(label: "test"))

        let layer = try fixture.onlyManifest().layers[0]
        #expect(layer.digest == "sha256:\(layerArchive.sha256Hex())")
        #expect(layer.size == layerArchive.count)
    }

    @Test("every legacy RepoTag keeps the runnable platform from its image config")
    func allRepoTagsKeepConfigPlatform() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }

        let configDigest = try fixture.writeConfig(
            architecture: "arm",
            os: "linux",
            variant: "v7",
            osVersion: "6.6",
            osFeatures: ["feature-a"]
        )
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: layerDigest,
            tags: ["first:latest", "second:latest"]
        )

        let loaded = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: fixture.dockerFormatDir,
            ociLayoutPath: fixture.ociLayoutDir,
            logger: Logger(label: "test")
        )
        let descriptors = try fixture.rawIndexDescriptors()

        #expect(loaded == ["first:latest", "second:latest"])
        #expect(descriptors.count == 2)
        #expect(
            Set(
                descriptors.compactMap { descriptor in
                    (descriptor["annotations"] as? [String: String])?[
                        "org.opencontainers.image.ref.name"
                    ]
                }) == ["first:latest", "second:latest"]
        )
        for descriptor in descriptors {
            let platform = try #require(
                descriptor["platform"] as? [String: Any]
            )
            #expect(platform["architecture"] as? String == "arm")
            #expect(platform["os"] as? String == "linux")
            #expect(platform["variant"] as? String == "v7")
            #expect(platform["os.version"] as? String == "6.6")
            #expect(platform["os.features"] as? [String] == ["feature-a"])
        }
    }

    @Test("legacy layer compression is represented by the matching OCI media type")
    func layerCompressionDeterminesOCIMediaType() async throws {
        let plainTar = Data(repeating: 0, count: 1024)
        let gzipTar = try #require(plainTar.gzip())
        let compressionFixture = try DockerArchiveFixture()
        defer { compressionFixture.cleanUp() }
        let zstdTar = try compressionFixture.zstdCompressed(plainTar)
        let cases = [
            (plainTar, "application/vnd.oci.image.layer.v1.tar"),
            (gzipTar, "application/vnd.oci.image.layer.v1.tar+gzip"),
            (zstdTar, "application/vnd.oci.image.layer.v1.tar+zstd"),
        ]

        for (content, expectedMediaType) in cases {
            let fixture = try DockerArchiveFixture()
            defer { fixture.cleanUp() }
            let configDigest = try fixture.writeConfig(
                diffIDs: ["sha256:\(plainTar.sha256Hex())"]
            )
            let layerDigest = try fixture.writeLayer(content: content)
            try fixture.writeManifest(
                configDigest: configDigest,
                layerDigest: layerDigest,
                tag: "compression:latest"
            )

            _ = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: fixture.dockerFormatDir,
                ociLayoutPath: fixture.ociLayoutDir,
                logger: Logger(label: "test")
            )

            #expect(
                try fixture.onlyManifest().layers[0].mediaType
                    == expectedMediaType
            )
        }
    }

    @Test("legacy manifest metadata is rejected above the JSON limit")
    func oversizedLegacyManifestIsRejected() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSparseFile(
            relativePath: "manifest.json",
            size: BoundedFileReader.maxImageMetadataBytes + 1
        )

        do {
            _ = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: fixture.dockerFormatDir,
                ociLayoutPath: fixture.ociLayoutDir,
                logger: Logger(label: "test")
            )
            Issue.record("expected oversized manifest.json to be rejected")
        } catch ContainerImageUtility.Error.invalidTarball(let reason) {
            #expect(reason.contains("manifest.json exceeds"))
            #expect(reason.contains("16777216-byte limit"))
        }
    }

    @Test("legacy config metadata is streamed to disk then rejected above the JSON limit")
    func oversizedLegacyConfigIsRejected() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let claimedDigest = String(repeating: "a", count: 64)
        try fixture.writeSparseFile(
            relativePath: "\(claimedDigest).json",
            size: BoundedFileReader.maxImageMetadataBytes + 1
        )
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: claimedDigest,
            layerDigest: layerDigest,
            tag: "oversized:latest"
        )

        do {
            _ = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: fixture.dockerFormatDir,
                ociLayoutPath: fixture.ociLayoutDir,
                logger: Logger(label: "test")
            )
            Issue.record("expected oversized image config to be rejected")
        } catch BoundedFileReadError.exceedsLimit(_, let maxBytes) {
            #expect(maxBytes == BoundedFileReader.maxImageMetadataBytes)
        }
    }

    @Test("OCI manifest metadata is rejected above the JSON limit")
    func oversizedOCIManifestIsRejected() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let manifestDigest = String(repeating: "b", count: 64)
        try fixture.writeSparseOCIBlob(
            digest: manifestDigest,
            size: BoundedFileReader.maxImageMetadataBytes + 1
        )
        try fixture.writeOCIIndex(
            manifestDigest: manifestDigest,
            manifestSize: BoundedFileReader.maxImageMetadataBytes + 1
        )

        do {
            _ = try await ContainerImageUtility.convertOCIToDockerTar(
                ociLayoutPath: fixture.ociLayoutDir,
                dockerFormatPath: fixture.dockerFormatDir,
                resolvedRefs: ["oversized:latest"],
                logger: Logger(label: "test")
            )
            Issue.record("expected oversized OCI manifest to be rejected")
        } catch BoundedFileReadError.exceedsLimit(let path, let maxBytes) {
            #expect(path == "blobs/sha256/\(manifestDigest)")
            #expect(maxBytes == BoundedFileReader.maxImageMetadataBytes)
        }
    }

    @Test("OCI config metadata is rejected above the JSON limit")
    func oversizedOCIConfigIsRejected() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let configDigest = String(repeating: "c", count: 64)
        try fixture.writeSparseOCIBlob(
            digest: configDigest,
            size: BoundedFileReader.maxImageMetadataBytes + 1
        )
        let manifest: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": [
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": "sha256:\(configDigest)",
                "size": BoundedFileReader.maxImageMetadataBytes + 1,
            ],
            "layers": [],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        let manifestDigest = try fixture.writeOCIBlob(manifestData)
        try fixture.writeOCIIndex(
            manifestDigest: manifestDigest,
            manifestSize: manifestData.count
        )

        do {
            _ = try await ContainerImageUtility.convertOCIToDockerTar(
                ociLayoutPath: fixture.ociLayoutDir,
                dockerFormatPath: fixture.dockerFormatDir,
                resolvedRefs: ["oversized:latest"],
                logger: Logger(label: "test")
            )
            Issue.record("expected oversized OCI config to be rejected")
        } catch BoundedFileReadError.exceedsLimit(let path, let maxBytes) {
            #expect(path == "blobs/sha256/\(configDigest)")
            #expect(maxBytes == BoundedFileReader.maxImageMetadataBytes)
        }
    }

    @Test(
        "non-canonical config paths are rejected before filesystem access",
        arguments: [
            "../canary.json",
            "../../canary.json",
            "/tmp/canary.json",
            "./" + String(repeating: "a", count: 64) + ".json",
            String(repeating: "A", count: 64) + ".json",
            "not-a-digest.json",
        ]
    )
    func invalidConfigPathIsRejected(path: String) async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let canary = fixture.root.appendingPathComponent("canary.json")
        let canaryData = Data("must remain untouched".utf8)
        try canaryData.write(to: canary)
        let layerDigest = try fixture.writeLayer()
        try fixture.writeRawManifest(
            config: path,
            layers: ["\(layerDigest)/layer.tar"]
        )

        try await assertConversionRejected(fixture)
        #expect(try Data(contentsOf: canary) == canaryData)
    }

    @Test(
        "non-canonical layer paths are rejected before filesystem access",
        arguments: [
            "../layer.tar",
            "../../canary/layer.tar",
            "/tmp/canary/layer.tar",
            "./" + String(repeating: "a", count: 64) + "/layer.tar",
            String(repeating: "a", count: 64) + "/../layer.tar",
            String(repeating: "A", count: 64) + "/layer.tar",
        ]
    )
    func invalidLayerPathIsRejected(path: String) async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let canary = fixture.root.appendingPathComponent("canary-layer.tar")
        let canaryData = Data("must remain untouched".utf8)
        try canaryData.write(to: canary)
        let configDigest = try fixture.writeConfig()
        try fixture.writeRawManifest(
            config: "\(configDigest).json",
            layers: [path]
        )

        try await assertConversionRejected(fixture)
        #expect(try Data(contentsOf: canary) == canaryData)
    }

    @Test("a canonical config filename cannot be a symlink to an external canary")
    func configSymlinkIsRejectedWithoutTouchingTarget() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let canary = fixture.root.appendingPathComponent("external-config.json")
        let canaryData = Data(
            #"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}"#.utf8
        )
        try canaryData.write(to: canary)
        let claimed = String(repeating: "a", count: 64)
        try FileManager.default.createSymbolicLink(
            at: fixture.dockerFormatDir.appendingPathComponent(
                "\(claimed).json"
            ),
            withDestinationURL: canary
        )
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: claimed,
            layerDigest: layerDigest,
            tag: "symlink:latest"
        )

        try await assertConversionRejected(fixture)
        #expect(try Data(contentsOf: canary) == canaryData)
    }

    @Test("a canonical layer directory cannot be a symlink outside the archive root")
    func layerDirectorySymlinkIsRejectedWithoutTouchingTarget() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let configDigest = try fixture.writeConfig()
        let claimed = String(repeating: "b", count: 64)
        let externalDirectory = fixture.root.appendingPathComponent(
            "external-layer",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: false
        )
        let canary = externalDirectory.appendingPathComponent("layer.tar")
        let canaryData = Data("external layer canary".utf8)
        try canaryData.write(to: canary)
        try FileManager.default.createSymbolicLink(
            at: fixture.dockerFormatDir.appendingPathComponent(claimed),
            withDestinationURL: externalDirectory
        )
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: claimed,
            tag: "symlink-layer:latest"
        )

        try await assertConversionRejected(fixture)
        #expect(try Data(contentsOf: canary) == canaryData)
    }

    @Test("a canonical config filename cannot hardlink an external canary")
    func configHardlinkIsRejectedWithoutTouchingTarget() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let canary = fixture.root.appendingPathComponent("external-hardlink.json")
        let canaryData = Data(
            #"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}"#.utf8
        )
        try canaryData.write(to: canary)
        let claimed = String(repeating: "c", count: 64)
        try FileManager.default.linkItem(
            at: canary,
            to: fixture.dockerFormatDir.appendingPathComponent(
                "\(claimed).json"
            )
        )
        let layerDigest = try fixture.writeLayer()
        try fixture.writeManifest(
            configDigest: claimed,
            layerDigest: layerDigest,
            tag: "hardlink:latest"
        )

        try await assertConversionRejected(fixture)
        #expect(try Data(contentsOf: canary) == canaryData)
    }

    @Test("a canonical layer filename cannot hardlink an external canary")
    func layerHardlinkIsRejectedWithoutTouchingTarget() async throws {
        let fixture = try DockerArchiveFixture()
        defer { fixture.cleanUp() }
        let configDigest = try fixture.writeConfig()
        let claimed = String(repeating: "d", count: 64)
        let layerDirectory = fixture.dockerFormatDir.appendingPathComponent(
            claimed,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: layerDirectory,
            withIntermediateDirectories: false
        )
        let canary = fixture.root.appendingPathComponent("external-layer.tar")
        let canaryData = Data("hardlinked layer canary".utf8)
        try canaryData.write(to: canary)
        try FileManager.default.linkItem(
            at: canary,
            to: layerDirectory.appendingPathComponent("layer.tar")
        )
        try fixture.writeManifest(
            configDigest: configDigest,
            layerDigest: claimed,
            tag: "hardlink-layer:latest"
        )

        try await assertConversionRejected(fixture)
        #expect(try Data(contentsOf: canary) == canaryData)
    }

    private func assertConversionRejected(
        _ fixture: DockerArchiveFixture,
        reasonContains expectedReason: String? = nil
    ) async throws {
        do {
            _ = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: fixture.dockerFormatDir,
                ociLayoutPath: fixture.ociLayoutDir,
                logger: Logger(label: "test")
            )
            Issue.record("expected hostile docker-archive member to fail")
        } catch ContainerImageUtility.Error.invalidTarball(let reason) {
            if let expectedReason {
                #expect(reason.contains(expectedReason))
            }
            return
        }
    }
}

private struct DockerArchiveFixture {
    let root: URL
    let dockerFormatDir: URL
    let ociLayoutDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docker-archive-\(UUID().uuidString)")
        dockerFormatDir = root.appendingPathComponent("docker-format")
        ociLayoutDir = root.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: dockerFormatDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ociLayoutDir, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private var defaultLayerContent: Data {
        // Two zero blocks are the canonical terminator for an empty tar layer.
        Data(repeating: 0, count: 1024)
    }

    private var defaultDiffID: String {
        "sha256:\(defaultLayerContent.sha256Hex())"
    }

    private var configContent: Data {
        Data(
            #"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":["\#(defaultDiffID)"]}}"#.utf8
        )
    }

    func writeConfig() throws -> String {
        let digest = configContent.sha256Hex()
        try configContent.write(to: dockerFormatDir.appendingPathComponent("\(digest).json"))
        return digest
    }

    func writeConfig(diffIDs: [String]) throws -> String {
        try writeConfig(
            architecture: "arm64",
            os: "linux",
            diffIDs: diffIDs
        )
    }

    func writeConfigWithoutRootFS() throws -> String {
        let content = try JSONSerialization.data(
            withJSONObject: [
                "architecture": "arm64",
                "os": "linux",
            ],
            options: [.sortedKeys]
        )
        let digest = content.sha256Hex()
        try content.write(
            to: dockerFormatDir.appendingPathComponent("\(digest).json")
        )
        return digest
    }

    func writeConfig(
        architecture: String,
        os: String,
        variant: String? = nil,
        osVersion: String? = nil,
        osFeatures: [String]? = nil,
        diffIDs: [String]? = nil
    ) throws -> String {
        var object: [String: Any] = [
            "architecture": architecture,
            "os": os,
            "rootfs": [
                "type": "layers",
                "diff_ids": diffIDs ?? [defaultDiffID],
            ],
        ]
        object["variant"] = variant
        object["os.version"] = osVersion
        object["os.features"] = osFeatures
        let content = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let digest = content.sha256Hex()
        try content.write(
            to: dockerFormatDir.appendingPathComponent("\(digest).json")
        )
        return digest
    }

    func writeConfigWithClaimedDigest(_ claimed: String) throws -> String {
        try configContent.write(to: dockerFormatDir.appendingPathComponent("\(claimed).json"))
        return configContent.sha256Hex()
    }

    func writeLayer(content: Data? = nil) throws -> String {
        let content = content ?? defaultLayerContent
        let digest = content.sha256Hex()
        try writeLayerContent(content, under: digest)
        return digest
    }

    func writeLayerWithClaimedDigest(_ claimed: String) throws -> String {
        let content = defaultLayerContent
        try writeLayerContent(content, under: claimed)
        return content.sha256Hex()
    }

    func makeLayerArchive(fileContent: Data) throws -> Data {
        let source = root.appendingPathComponent(
            "layer-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let archive = root.appendingPathComponent(
            "layer-\(UUID().uuidString).tar"
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: archive)
        }
        try fileContent.write(to: source.appendingPathComponent("payload"))
        try ArchiveUtility.create(tarPath: archive, from: source)
        return try Data(contentsOf: archive)
    }

    func zstdCompressed(_ content: Data) throws -> Data {
        let source = root.appendingPathComponent(
            "zstd-source-\(UUID().uuidString).tar"
        )
        let destination = root.appendingPathComponent(
            "zstd-layer-\(UUID().uuidString).tar.zst"
        )
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try content.write(to: source)
        try ZstdTestSupport.compress(
            source: source,
            destination: destination
        )
        return try Data(contentsOf: destination)
    }

    func loadLayerStagingDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: ociLayoutDir.path
        ).filter {
            $0.hasPrefix("glassdock-compressed-import-")
        }
    }

    private func writeLayerContent(_ content: Data, under digest: String) throws {
        let layerDir = dockerFormatDir.appendingPathComponent(digest)
        try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)
        try content.write(to: layerDir.appendingPathComponent("layer.tar"))
    }

    func writeManifest(configDigest: String, layerDigest: String, tag: String) throws {
        try writeManifests([(config: configDigest, layer: layerDigest, tag: tag)])
    }

    func writeManifest(
        configDigest: String,
        layerDigest: String,
        tags: [String]
    ) throws {
        let manifest: [[String: Any]] = [
            [
                "Config": "\(configDigest).json",
                "RepoTags": tags,
                "Layers": ["\(layerDigest)/layer.tar"],
            ]
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: dockerFormatDir.appendingPathComponent("manifest.json"))
    }

    func writeManifests(_ entries: [(config: String, layer: String, tag: String)]) throws {
        let objects = entries.map {
            #"{"Config":"\#($0.config).json","RepoTags":["\#($0.tag)"],"Layers":["\#($0.layer)/layer.tar"]}"#
        }
        let manifest = "[\(objects.joined(separator: ","))]"
        try Data(manifest.utf8).write(to: dockerFormatDir.appendingPathComponent("manifest.json"))
    }

    func writeRawManifest(config: String, layers: [String]) throws {
        let manifest: [[String: Any]] = [
            [
                "Config": config,
                "RepoTags": ["hostile:latest"],
                "Layers": layers,
            ]
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(
            to: dockerFormatDir.appendingPathComponent("manifest.json")
        )
    }

    func writeSparseFile(relativePath: String, size: Int) throws {
        let path = dockerFormatDir.appendingPathComponent(relativePath)
        #expect(FileManager.default.createFile(atPath: path.path, contents: nil))
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    func writeOCIIndex(manifestDigest: String, manifestSize: Int) throws {
        let index: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": [
                [
                    "mediaType":
                        "application/vnd.oci.image.manifest.v1+json",
                    "digest": "sha256:\(manifestDigest)",
                    "size": manifestSize,
                ]
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: index,
            options: [.sortedKeys]
        ).write(to: ociLayoutDir.appendingPathComponent("index.json"))
    }

    @discardableResult
    func writeOCIBlob(_ data: Data) throws -> String {
        let digest = data.sha256Hex()
        let blobs = ociLayoutDir.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(
            at: blobs,
            withIntermediateDirectories: true
        )
        try data.write(to: blobs.appendingPathComponent(digest))
        return digest
    }

    func writeSparseOCIBlob(digest: String, size: Int) throws {
        let blobs = ociLayoutDir.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(
            at: blobs,
            withIntermediateDirectories: true
        )
        let path = blobs.appendingPathComponent(digest)
        #expect(FileManager.default.createFile(atPath: path.path, contents: nil))
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    func onlyManifest() throws -> OCILayoutManifest {
        try allManifests()[0]
    }

    func allManifests() throws -> [OCILayoutManifest] {
        let index = try JSONDecoder().decode(OCILayoutIndex.self, from: Data(contentsOf: ociLayoutDir.appendingPathComponent("index.json")))
        return try index.manifests.map {
            let manifestDigest = $0.digest.replacingOccurrences(of: "sha256:", with: "")
            return try JSONDecoder().decode(OCILayoutManifest.self, from: Data(contentsOf: blobURL(manifestDigest)))
        }
    }

    func rawIndexDescriptors() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(
            with: Data(
                contentsOf: ociLayoutDir.appendingPathComponent("index.json")
            )
        )
        let index = try #require(object as? [String: Any])
        return try #require(index["manifests"] as? [[String: Any]])
    }

    func blobExists(_ digest: String) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(digest.replacingOccurrences(of: "sha256:", with: "")).path)
    }

    private func blobURL(_ hex: String) -> URL {
        ociLayoutDir.appendingPathComponent("blobs/sha256/\(hex)")
    }
}
