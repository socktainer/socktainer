import ContainerizationArchive
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

        let content = "hello from import\n"
        let tarPath = try fixture.makeTar(fileContents: content)
        let tarData = try Data(contentsOf: tarPath)
        let expectedDiffID = "sha256:\(tarData.sha256Hex())"

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
        #expect(manifest.layers[0].mediaType == MediaTypes.imageLayerGzip)

        // Compressed bytes are an implementation detail of the gzip encoder,
        // so this checks self-consistency and correct decompression instead
        // of a byte-for-byte match.
        let layerData = try fixture.blobData(manifest.layers[0].digest)
        #expect(manifest.layers[0].digest == "sha256:\(layerData.sha256Hex())")
        let layerPath = fixture.root.appendingPathComponent("layer.tar.gz")
        try layerData.write(to: layerPath)
        #expect(try GzipStreamDecoder.sha256OfDecompressedContent(at: layerPath, cap: 10_000_000) == tarData.sha256Hex())

        let config = try fixture.config(manifest)
        #expect(config.rootfs.diffIDs == [expectedDiffID])
        #expect(config.architecture == "arm64")
        #expect(config.os == "linux")
    }

    /// `tar cf scratch.tar -T /dev/null` (two 512-byte zero blocks, no file
    /// entries) is the standard idiom for building a "scratch" base image, and
    /// real `docker import` accepts it. This is a structurally valid, empty
    /// tar — not a foreign format — so the tar-family confirmation check must
    /// tell it apart from actual foreign content (which produces a spurious,
    /// path-less entry instead of a clean EOF).
    @Test("a zero-entry (scratch) tar is accepted, not treated as a foreign format")
    func zeroEntryTarIsAccepted() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = fixture.root.appendingPathComponent("scratch.tar")
        try Data(repeating: 0, count: 1024).write(to: tarPath)

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
    }

    @Test("a gzip-wrapped zero-entry tar is also accepted")
    func gzipWrappedZeroEntryTarIsAccepted() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let tarPath = fixture.root.appendingPathComponent("scratch.tar.gz")
        try #require(Data(repeating: 0, count: 1024).gzip()).write(to: tarPath)

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

        // diff_id must be the digest of the real decompressed layer content —
        // not the still-compressed input, and not disconnected from what's
        // actually stored. Independently decompress the stored blob (gunzip
        // for bzip2/xz, which are reserialized to gzip; the zstd decoder for
        // zstd, which is stored as-is) and compare hashes directly, rather
        // than only asserting the layer's file contents extract correctly.
        let decompressed: Data
        if fixtureCase.format == "zstd" {
            let decompressedPath = try ArchiveReader.decompressZstd(layerPath)
            defer { ArchiveReader.cleanUpDecompressedZstd(decompressedPath) }
            decompressed = try Data(contentsOf: decompressedPath)
        } else {
            decompressed = try #require(layerData.gunzip())
        }
        let expectedDiffID = "sha256:\(decompressed.sha256Hex())"
        #expect(try fixture.config(manifest).rootfs.diffIDs == [expectedDiffID])
    }

    @Test(
        "a bzip2/xz/zstd layer whose decompressed size exceeds the configured cap is rejected",
        arguments: reserializeFixtures)
    func decompressedContentExceedingCapIsRejected(fixtureCase: (format: String, base64: String, expectedMediaType: String)) async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let compressedPath = fixture.root.appendingPathComponent("cap-\(fixtureCase.format).tar")
        try #require(Data(base64Encoded: fixtureCase.base64)).write(to: compressedPath)

        do {
            _ = try ContainerImageUtility.buildSingleLayerOCILayout(
                tarPath: compressedPath,
                ociLayoutPath: fixture.ociLayoutDir,
                platform: Platform(arch: "arm64", os: "linux"),
                config: SynthesizedImageConfig(),
                message: nil,
                reference: nil,
                logger: fixture.logger,
                maxExpandedLayerSize: 10
            )
            Issue.record("expected \(fixtureCase.format) import exceeding the cap to be rejected")
        } catch ContainerImageUtility.Error.invalidTarball(let reason) {
            #expect(reason.contains("exceeds"))
        }
    }

    @Test("a gzip layer whose decompressed size exceeds the configured cap is rejected")
    func gzipDecompressedContentExceedingCapIsRejected() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let plainTarPath = try fixture.makeTar(fileContents: "reserialize round-trip\n")
        let gzipPath = fixture.root.appendingPathComponent("cap-gzip.tar.gz")
        try #require(try Data(contentsOf: plainTarPath).gzip()).write(to: gzipPath)

        do {
            _ = try ContainerImageUtility.buildSingleLayerOCILayout(
                tarPath: gzipPath,
                ociLayoutPath: fixture.ociLayoutDir,
                platform: Platform(arch: "arm64", os: "linux"),
                config: SynthesizedImageConfig(),
                message: nil,
                reference: nil,
                logger: fixture.logger,
                maxExpandedLayerSize: 10
            )
            Issue.record("expected a gzip import exceeding the cap to be rejected")
        } catch ContainerImageUtility.Error.invalidTarball(let reason) {
            #expect(reason.contains("exceeds"))
        }
    }

    @Test("many empty entries are still bounded by the cap even though their content bytes alone round to zero")
    func manyEmptyEntriesAreBoundedByHeaderAccounting() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        // Plain (uncompressed), not gzip-wrapped: a gzip layer's expansion cap
        // is separately enforced by `GzipStreamDecoder` over the raw
        // decompressed byte stream (headers included), which would catch an
        // undercounting bug here for the wrong reason. A plain tar isolates
        // `validateTar`'s own per-entry accounting, since `writeImportedLayerBlob`
        // applies no expansion cap at all to an already-uncompressed input.
        for i in 0..<2000 {
            try Data().write(to: fixture.rootfsDir.appendingPathComponent("empty-\(i)"))
        }
        let tarPath = fixture.root.appendingPathComponent("many-empty.tar")
        try ArchiveUtility.create(tarPath: tarPath, from: fixture.rootfsDir)

        do {
            _ = try ContainerImageUtility.buildSingleLayerOCILayout(
                tarPath: tarPath,
                ociLayoutPath: fixture.ociLayoutDir,
                platform: Platform(arch: "arm64", os: "linux"),
                config: SynthesizedImageConfig(),
                message: nil,
                reference: nil,
                logger: fixture.logger,
                maxExpandedLayerSize: 100_000
            )
            Issue.record("expected many-empty-entry import exceeding the cap via header/padding accounting to be rejected")
        } catch ContainerImageUtility.Error.invalidTarball(let reason) {
            #expect(reason.contains("exceeds"))
        }
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

    /// A gzip-wrapped zip: `classifyLayerSource` sees gzip at the outer magic
    /// bytes and only the tar-family confirmation gate (not the magic-byte
    /// blacklist, which never looks past the outer layer) catches that the
    /// decompressed content isn't tar.
    private static let gzipWrappedZipBase64 =
        "H4sICKyaWGoAA3ppcC1hcmNoaXZlLnppcAAL8GZm4WIAgS+hH2IYkAAHgwxDcn5eSWpeiX5oCCcD8+pZEVkgXFrBzcDI8o2RgYEFpC4AxQRda471PEA2CAsgmZCWmZOqV1JRgs+kjNScnHyF8vyinBSuAJzuQjY1Jz8vPSWziAT3+Xyc1MULZIPwMiwmJQ5KgM9/IJcrQL2BJ9j4kTxbXJpEWqghx6o4pkE5mXnZpEUuI5McM65kJwGP6LeOIBqRCFkhpmM4FdU01CQIMQ2olmFJoxOSaYgESZypqEkQ2Y0zkExFJEjiTEVNjshufYTF1IFOhtgBOSHIjxKC5xkZMNMm6ZEtjhKAEkwYhiLSKS7DWdlANBsQzgBqL2UC8QDH16NZIwUAAA=="

    @Test("a gzip-wrapped zip is rejected, not just a bare zip")
    func gzipWrappedZipIsRejectedCleanly() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let bodyPath = fixture.root.appendingPathComponent("import.tar")
        try #require(Data(base64Encoded: Self.gzipWrappedZipBase64)).write(to: bodyPath)

        try assertRejected(bodyPath: bodyPath, fixture: fixture, expectedFormat: "not a supported docker import source")
    }

    /// A real `xar` archive (macOS's `xar -cf`) — a libarchive-readable
    /// container format with no distinctive-enough magic bytes to be worth a
    /// dedicated blacklist entry, exercising the tar-family confirmation gate
    /// (added alongside the blacklist) against a format the blacklist never
    /// covered at all.
    private static let xarBase64 =
        "eGFyIQAcAAEAAAAAAAACVwAAAAAAAAVdAAAAAXjatFRNb6MwEL33VyDuxGOD+YhcelipvyB72Zuxh8RaMBGQbNpfv7YhzVZNe6i0J8bPb2bsZ96Ip0vfRWccJzPYx5huII7QqkEbu3+Mf+6ekzJ+qh/ERY71QyTmQblPJNSIcnYZyWx6rBmwPIEiofkOqi2DLQdB3lNC0gHV7+nUR9P80uFjPB0kjf1OJIa2nXCuXdoaBXQyr764ICHwJci1Rli1psPIaHfstYyWswxRJDq0+/kQstdwwdf6afWu1dqLslsvh12FuB5YHo+dUeFW5JLsX80xJlfqZR6lmlEn92/JGK/yNE+bVGMGDeRtVdK2KbkuWUoZlgpQc0oF+VhpbSFHdTDnTztImbYlqEJx5AAlq4A3VLcNl1mOTct4AVxxiYJ8KLSIR97UEyiDrBC/F5NW98VkcFdM+r/ERIS2lSVtsiZlGdOcN6DykqbcyVpkvFQSVAb8+2IC14XMUq01AKVMcZ1lSIuUIhSMaZQ5aI55/pmYkbDS/fVq6Df+nrg5jsMZrbTK6R+2FslxFfzZWI3jD28Z3K1+CUXsMKEarJ68N/5dLoTgLVoBJEATgB1jW8q3rBTk6jrX5G5xoT5Yt9xmxTatfjmX3bL7L2j9jSa/oMkbbT8Op2P954DYCbIsFtxof0H/CevThGM9vXRnaezGqdjgJEgAl23H4+DMerom9IPGGvIsc6fy4TIO8GwU2qGmeVEULHUJb1AgGOu51LmFFhlz/+sChL355Yi1nzBOSx8+vL2qBzfzZb69pCAe8wOShAkpSJiXfwEAAP//AwAHkJqpqPqpEol7Pvd4RO/qGfoSUaLpKPZ42mNkYohMT8zlzHdaDQAMygL3eNrLSM3JyVcozy/KSeECAB5yBGc="

    @Test("a xar archive is rejected instead of silently hashed as raw bytes")
    func xarBodyIsRejectedCleanly() async throws {
        let fixture = try ImportFixture()
        defer { fixture.cleanUp() }

        let bodyPath = fixture.root.appendingPathComponent("import.tar")
        try #require(Data(base64Encoded: Self.xarBase64)).write(to: bodyPath)

        try assertRejected(bodyPath: bodyPath, fixture: fixture, expectedFormat: "not a supported docker import source")
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
