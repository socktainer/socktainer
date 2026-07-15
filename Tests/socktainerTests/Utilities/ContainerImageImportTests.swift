import ContainerizationOCI
import CryptoKit
import DataCompression
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("buildSingleLayerOCILayout — docker import")
struct ContainerImageImportTests {

    @Test("a bare import (no repo, no changes) produces a single-layer OCI layout with the right diff_id")
    func bareImportProducesSingleLayerLayout() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(fileContents: "hello from import\n")
        let tarData = try Data(contentsOf: tarPath)
        let expectedDiffID = "sha256:\(tarData.sha256Hex())"
        // moby's docker import always gzip-compresses an uncompressed input before
        // storing it (daemon/containerd/image_import.go) — it never stores a plain
        // tar layer — so the manifest's layer digest is the compressed hash, distinct
        // from diff_id, which stays the uncompressed hash.
        let expectedLayerDigest = "sha256:\(tarData.gzip()!.sha256Hex())"

        _ = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: tarPath,
            ociLayoutPath: fixture.ociLayoutDir,
            platform: Platform(arch: "arm64", os: "linux"),
            config: SynthesizedImageConfig(),
            message: nil,
            reference: nil,
            logger: fixture.logger
        )

        let index = try fixture.index()
        #expect(index.manifests.count == 1)
        #expect(index.manifests[0].annotations == nil)

        let manifest = try fixture.manifest(index.manifests[0])
        #expect(manifest.layers.count == 1)
        #expect(manifest.layers[0].digest == expectedLayerDigest)
        #expect(manifest.layers[0].mediaType == MediaTypes.imageLayerGzip)

        let config = try fixture.config(manifest)
        #expect(config.rootfs.diffIDs == [expectedDiffID])
        #expect(config.architecture == "arm64")
        #expect(config.os == "linux")
    }

    @Test("a repo:tag reference registers the tag via the manifest annotation")
    func repoTagRegistersAnnotation() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(fileContents: "tagged content\n")

        _ = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: tarPath,
            ociLayoutPath: fixture.ociLayoutDir,
            platform: Platform(arch: "arm64", os: "linux"),
            config: SynthesizedImageConfig(),
            message: nil,
            reference: "docker.io/library/crafted-import:latest",
            logger: fixture.logger
        )

        let index = try fixture.index()
        #expect(index.manifests[0].annotations?["org.opencontainers.image.ref.name"] == "docker.io/library/crafted-import:latest")
    }

    @Test("a message sets the image history comment")
    func messageSetsHistoryComment() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(fileContents: "commented content\n")

        _ = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: tarPath,
            ociLayoutPath: fixture.ociLayoutDir,
            platform: Platform(arch: "arm64", os: "linux"),
            config: SynthesizedImageConfig(),
            message: "Imported from -",
            reference: nil,
            logger: fixture.logger
        )

        let manifest = try fixture.manifest(try fixture.index().manifests[0])
        let config = try fixture.config(manifest)
        #expect(config.history?.first?.comment == "Imported from -")
    }

    @Test("changes (CMD, ENV, EXPOSE) are applied to the synthesized config")
    func changesApplyToConfig() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(fileContents: "content\n")

        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(
            [
                "CMD [\"/app\", \"serve\"]",
                "ENV FOO=bar",
                "EXPOSE 8080/tcp",
            ], to: &config)

        _ = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: tarPath,
            ociLayoutPath: fixture.ociLayoutDir,
            platform: Platform(arch: "arm64", os: "linux"),
            config: config,
            message: nil,
            reference: nil,
            logger: fixture.logger
        )

        let manifest = try fixture.manifest(try fixture.index().manifests[0])
        let ociImage = try fixture.config(manifest)
        #expect(ociImage.config?.cmd == ["/app", "serve"])
        #expect(ociImage.config?.env == ["FOO=bar"])

        // ContainerizationOCI.ImageConfig has no ExposedPorts field, so assert
        // against the raw JSON to prove EXPOSE is actually persisted in the blob.
        let rawConfig = try fixture.rawConfigDict(manifest)
        let configObject = try #require(rawConfig["config"] as? [String: Any])
        let exposedPorts = try #require(configObject["ExposedPorts"] as? [String: Any])
        #expect(exposedPorts["8080/tcp"] != nil)
    }

    @Test("a gzip-compressed body's diff_id is the uncompressed content hash, not the compressed file hash")
    func gzipImportUsesDecompressedContentForDiffID() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let plainTarPath = try fixture.makeTar(fileContents: "gzip round-trip\n")
        let plainTarData = try Data(contentsOf: plainTarPath)
        let expectedDiffID = "sha256:\(plainTarData.sha256Hex())"
        let compressed = plainTarData.gzip()!
        let expectedLayerDigest = "sha256:\(compressed.sha256Hex())"
        let gzipPath = fixture.root.appendingPathComponent("import.tar.gz")
        try compressed.write(to: gzipPath)

        _ = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: gzipPath,
            ociLayoutPath: fixture.ociLayoutDir,
            platform: Platform(arch: "arm64", os: "linux"),
            config: SynthesizedImageConfig(),
            message: nil,
            reference: nil,
            logger: fixture.logger
        )

        let manifest = try fixture.manifest(try fixture.index().manifests[0])
        // The manifest layer descriptor's digest is the stored (compressed) blob's
        // digest; rootfs.diffIDs is the uncompressed content's digest — these must
        // differ for a gzip layer, which is exactly the distinction the compression
        // fix depends on getting right.
        #expect(manifest.layers[0].digest == expectedLayerDigest)
        #expect(manifest.layers[0].mediaType == "application/vnd.oci.image.layer.v1.tar+gzip")
        #expect(try fixture.config(manifest).rootfs.diffIDs == [expectedDiffID])
    }

    /// `.tar` containing one `hello.txt` with contents `"reserialize round-trip\n"`,
    /// compressed with each codec — `ArchiveWriter` can't encode bzip2/xz/zstd in
    /// this environment (only decode, which is what production code needs), so
    /// these are baked in rather than generated by the test at runtime.
    ///
    /// moby stores zstd input as-is (`tar+zstd`); bzip2/xz are decompressed and
    /// re-compressed to gzip (`tar+gzip`) since OCI has no bzip2/xz layer media type.
    private static let reserializeFixtures: [(format: String, base64: String, expectedMediaType: String)] = [
        (
            "bzip2",
            "QlpoOTFBWSZTWRkuyEcAAHr/sf65A4BQA//iOmb/8P7n//AAQA4IABAACDABWVCDKaaFJtR6j1PUGmm0QGhoaAYQaMmTTI9JtQ4yZNGIaaGAmhiaNMmIGRhNGmmEGTDakVG9TJplPUYRoaGQNAAGgDT1AaaG1MEdB4GT2KcdxOtDZdByTfFeb9TklZYNZq+fUekKdkOZAsVl1tkjavxvnSPocKJMkKNsDEisCToOWVlhco3c9bXcTYYYwbRYVOqfZwlAtRpjt+a1YDI6iU7wzkD7KMObOpEjnnckiU4xkd+Kh5pFQ62HjEZGbLwQxhDTVTjfBbKAQRELzXdQqAX67X6xXrjewhHuLC8uLrzVAi1IKXwasz6p2PS9gEw4rmPALnzhwianMEyYs2jK36e1sKTE5HRKbDDZqRGf9FswOI7QzT95ngc1IhGyXaPspSZv0zIWGQ3/Wsbt8LpM+jS+pKUkjOEqhaeWgqOkG7eYgZhWqmNW0SJQkIGoXpXkyk7WdLVHmRpjCXy4XYllkUxNZpLSTiknhBRFYsRlLHSmSX+LuSKcKEgMl2QjgA==",
            "application/vnd.oci.image.layer.v1.tar+gzip"
        ),
        (
            "xz",
            "/Td6WFoAAATm1rRGBMDOAoAgIQEWAAAAAAAAAPrQkD7gD/8BRl0AFxfJBlOXkB3hI639Z/BGKdQsiNk3G5TXgSL/9PGJePOERCMsgYG7SRkm7x/x1QlB6IymM77jwvL+3uVRKpSuVgGKzX27zZpn1ukRtdADafE3gYjzDdb3EILHfcfYnJObF/wZoI6eEcxwHyAaZtL37BFqSf3+2TcHRTRzPV38HQlp48FUM29Mo4EvotRBel/qM+pR0IszPtGiWUIkjgiUZOJE4T02wYToEVcYHi87qdxcuGtOdRjMEd9fzz7SCk5QGzBDuQ3huy4/0RsxqQK2WWigdxfN7TA3WNrdfgxNMlMI3WJAJFJDcOUtm4zZcIsi74/RbxAYsGb9W9hApQqcj3RYkkDhv5f2D8P8Pno2PbU2LiDbt/A18/vscNJpIqaKQZT54XU+4o1AqJoOTRq70Jch5aqr9WOh0GpVxWuMEj+6SLNa7QAAAAD6JSwLckZHRQAB6gKAIAAAgk9e27HEZ/sCAAAAAARZWg==",
            "application/vnd.oci.image.layer.v1.tar+gzip"
        ),
        (
            "zstd",
            "KLUv/WQADyULAPYQPS4wpWobgFwKQ0EBpSp+u9FNwHgoQ3QPVHpuXX5hRQAZQ3b7u0ka1MClXAsMRigFLAAwADAAHAuj3FXRUI3Q3NnSq4G8GXrP55G7fC9G7YDP3d2lnA2hdHe+23VYre9xcAHURa8PYTZzX7OMOgujCBQDzDxxyWQkAMwfZn7MzODuhsYoNEUTmBcsUBDQ9d8DoX2SqdIzNiD0Byd8SAeBxBcj+JhR5K3qWu2OrfnFKT06sN+hT9noQgAJxrDow4YXCv5ZZa9B5wJhtl+iqrSyr72d7rGxqUyUCaYhsKF9LKFq4Xg6Go00WaSIs/fSzSEwTJTJRQoqINCCESot0AP9aStwTQE7yVZtYwOo0gncTxYGEANguPxOkIEsqTv/OIidGSI7vcFQtzscQMZwC9CETE0F6ZS/wbettQ2eUSP+Tl5eC86wlUjBqPmwIUckkFRXYBzNB6BJDAltmBw4N9auySUBAxjqzA==",
            "application/vnd.oci.image.layer.v1.tar+zstd"
        ),
    ]

    @Test(
        "a compressed body reserializes with the diff_id reflecting real content, not compressed bytes",
        arguments: reserializeFixtures)
    func reserializedCompressionUsesRealContentForDiffID(fixtureCase: (format: String, base64: String, expectedMediaType: String)) async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let content = "reserialize round-trip\n"
        let compressedPath = fixture.root.appendingPathComponent("import-\(fixtureCase.format).tar")
        try #require(Data(base64Encoded: fixtureCase.base64)).write(to: compressedPath)

        _ = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: compressedPath,
            ociLayoutPath: fixture.ociLayoutDir,
            platform: Platform(arch: "arm64", os: "linux"),
            config: SynthesizedImageConfig(),
            message: nil,
            reference: nil,
            logger: fixture.logger
        )

        let manifest = try fixture.manifest(try fixture.index().manifests[0])
        #expect(manifest.mediaType == "application/vnd.oci.image.manifest.v1+json")
        #expect(manifest.layers[0].mediaType == fixtureCase.expectedMediaType)

        let layerData = try fixture.blobData(manifest.layers[0].digest)
        let extractDir = fixture.root.appendingPathComponent("extracted-\(fixtureCase.format)")
        let layerPath = fixture.root.appendingPathComponent("layer-\(fixtureCase.format).tar")
        try layerData.write(to: layerPath)
        try ArchiveUtility.extract(tarPath: layerPath, to: extractDir)
        #expect(try String(contentsOf: extractDir.appendingPathComponent("hello.txt"), encoding: .utf8) == content)
    }

    @Test("a zip body is rejected instead of silently hashed as raw bytes")
    func zipBodyIsRejectedCleanly() async throws {
        try assertForeignFormatRejected(magic: [0x50, 0x4b, 0x03, 0x04], expectedFormat: "zip")
    }

    @Test("a 7z body is rejected instead of silently hashed as raw bytes")
    func sevenZipBodyIsRejectedCleanly() async throws {
        try assertForeignFormatRejected(magic: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], expectedFormat: "7z")
    }

    @Test("a rar body is rejected instead of silently hashed as raw bytes")
    func rarBodyIsRejectedCleanly() async throws {
        try assertForeignFormatRejected(magic: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07], expectedFormat: "rar")
    }

    @Test("an ar body is rejected instead of silently hashed as raw bytes")
    func arBodyIsRejectedCleanly() async throws {
        try assertForeignFormatRejected(magic: Array("!<arch>\n".utf8), expectedFormat: "ar")
    }

    @Test("a cpio body is rejected instead of silently hashed as raw bytes")
    func cpioBodyIsRejectedCleanly() async throws {
        try assertForeignFormatRejected(magic: Array("070701".utf8), expectedFormat: "cpio")
    }

    @Test("an iso9660 body is rejected instead of silently hashed as raw bytes")
    func iso9660BodyIsRejectedCleanly() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let bodyPath = fixture.root.appendingPathComponent("import.tar")
        var bytes = Data(repeating: 0, count: 32769 + 5)
        bytes.replaceSubrange(32769..<32774, with: Data("CD001".utf8))
        try bytes.write(to: bodyPath)

        try assertRejected(bodyPath: bodyPath, fixture: fixture, expectedFormat: "iso9660")
    }

    private func assertForeignFormatRejected(magic: [UInt8], expectedFormat: String) throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let bodyPath = fixture.root.appendingPathComponent("import.tar")
        try Data(magic + [UInt8](repeating: 0, count: 512)).write(to: bodyPath)

        try assertRejected(bodyPath: bodyPath, fixture: fixture, expectedFormat: expectedFormat)
    }

    private func assertRejected(bodyPath: URL, fixture: ImportFixture, expectedFormat: String) throws {
        do {
            _ = try ContainerImageUtility.buildSingleLayerOCILayout(
                tarPath: bodyPath,
                ociLayoutPath: fixture.ociLayoutDir,
                platform: Platform(arch: "arm64", os: "linux"),
                config: SynthesizedImageConfig(),
                message: nil,
                reference: nil,
                logger: fixture.logger
            )
            Issue.record("expected \(expectedFormat) import to be rejected")
        } catch ContainerImageUtility.Error.invalidTarball(let reason) {
            #expect(reason.contains(expectedFormat))
        }
    }

    @Test("an empty request body fails cleanly")
    func emptyBodyFailsCleanly() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let emptyPath = fixture.root.appendingPathComponent("empty.tar")
        try Data().write(to: emptyPath)

        #expect(throws: ContainerImageUtility.Error.self) {
            try ContainerImageUtility.buildSingleLayerOCILayout(
                tarPath: emptyPath,
                ociLayoutPath: fixture.ociLayoutDir,
                platform: Platform(arch: "arm64", os: "linux"),
                config: SynthesizedImageConfig(),
                message: nil,
                reference: nil,
                logger: fixture.logger
            )
        }
    }

    @Test("a malformed (non-tar) request body fails cleanly")
    func malformedBodyFailsCleanly() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let garbagePath = fixture.root.appendingPathComponent("garbage.tar")
        try Data(repeating: 0xFF, count: 512).write(to: garbagePath)

        #expect(throws: ContainerImageUtility.Error.self) {
            try ContainerImageUtility.buildSingleLayerOCILayout(
                tarPath: garbagePath,
                ociLayoutPath: fixture.ociLayoutDir,
                platform: Platform(arch: "arm64", os: "linux"),
                config: SynthesizedImageConfig(),
                message: nil,
                reference: nil,
                logger: fixture.logger
            )
        }
    }
}

private struct ImportFixture {
    let root: URL
    let rootfsDir: URL
    let ociLayoutDir: URL
    let logger = Logger(label: "test")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("import-fixture-\(UUID().uuidString)")
        rootfsDir = root.appendingPathComponent("rootfs")
        ociLayoutDir = root.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: rootfsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ociLayoutDir, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeTar(fileContents: String) throws -> URL {
        try Data(fileContents.utf8).write(to: rootfsDir.appendingPathComponent("hello.txt"))
        let tarPath = root.appendingPathComponent("import.tar")
        try ArchiveUtility.create(tarPath: tarPath, from: rootfsDir)
        return tarPath
    }

    func index() throws -> Index {
        try JSONDecoder().decode(Index.self, from: Data(contentsOf: ociLayoutDir.appendingPathComponent("index.json")))
    }

    func manifest(_ descriptor: Descriptor) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: blob(descriptor.digest))
    }

    func config(_ manifest: Manifest) throws -> ContainerizationOCI.Image {
        try JSONDecoder().decode(ContainerizationOCI.Image.self, from: blob(manifest.config.digest))
    }

    func rawConfigDict(_ manifest: Manifest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: blob(manifest.config.digest))
        return try #require(object as? [String: Any])
    }

    func blobData(_ digest: String) throws -> Data {
        try blob(digest)
    }

    private func blob(_ digest: String) throws -> Data {
        let hex = digest.replacingOccurrences(of: "sha256:", with: "")
        return try Data(contentsOf: ociLayoutDir.appendingPathComponent("blobs/sha256/\(hex)"))
    }
}
