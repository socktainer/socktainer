import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import Logging

enum ContainerImageUtility {

    struct SynthesizedLayoutIdentity: Sendable, Equatable {
        let manifestDigest: String
        let configDigest: String
    }

    enum Error: Swift.Error {
        case invalidTarball(reason: String)
    }

    /// Bounds decompressed gzip content the same way `maxImportBodySize`
    /// bounds the upload itself, so a small, extreme-ratio malicious layer
    /// can't expand past a reasonable ceiling before being rejected.
    private static let maxExpandedLayerSize = 8 * 1024 * 1024 * 1024

    /// A root filesystem can legitimately contain far more entries than an
    /// OCI envelope, especially for language dependency trees. Keep generous
    /// headroom while independently bounding empty-header CPU/inode attacks
    /// that fit under the expanded-byte ceiling.
    private static let maxImportTarEntries = 250_000

    /// A legacy `docker load` layer is already contained by the 64-GiB image
    /// archive extraction budget. Use that same explicit ceiling when a
    /// compressed layer has to be expanded to verify its Docker diffID; the
    /// smaller `docker import` limit must not silently narrow load semantics.
    private static let maxExpandedLoadLayerSize = Int(
        ArchiveUtility.ExtractionLimits.imageLoad.maxExpandedBytes
    )

    /// Tar pads every entry to a 512-byte boundary (a header block plus a
    /// content block rounded up), so counting only the bytes `entryReader.read`
    /// returns undercounts the real decompressed size — an archive of millions
    /// of empty files would count as ~0 bytes despite the header-parsing and
    /// (for `reserializeToPlainTar`) header-writing cost being real.
    private static let tarBlockSize = 512

    private static func tarBlockPadding(forContentSize contentSize: Int) -> Int {
        (tarBlockSize - contentSize % tarBlockSize) % tarBlockSize
    }

    static func convertDockerTarToOCI(
        dockerFormatPath: URL,
        ociLayoutPath: URL,
        logger: Logger
    ) async throws -> [String] {
        let archiveRoot = try DockerArchiveRoot(url: dockerFormatPath)
        guard
            let manifestData = try archiveRoot.readManifest(
                maxBytes: 16 * 1024 * 1024
            )
        else {
            throw Error.invalidTarball(reason: "manifest.json not found")
        }
        let dockerManifests = try JSONDecoder().decode([TarManifest].self, from: manifestData)

        // Validate the cheap envelope invariants before authoring any OCI
        // output. Content/member validation below is also fail-closed: no bad
        // entry may be skipped to silently create a different archive image.
        for dockerManifest in dockerManifests {
            try Task.checkCancellation()
            guard dockerManifest.config != nil else {
                throw Error.invalidTarball(
                    reason: "docker-archive manifest entry is missing Config"
                )
            }
            guard dockerManifest.layers != nil else {
                throw Error.invalidTarball(
                    reason: "docker-archive manifest entry is missing Layers"
                )
            }
            try validateDockerArchiveRepoTags(dockerManifest.repoTags ?? [])
        }

        let blobsDir = ociLayoutPath.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let ociLayout = "{\"imageLayoutVersion\": \"1.0.0\"}"
        try ociLayout.write(to: ociLayoutPath.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)

        var indexManifests: [[String: Any]] = []
        var loadedImages: [String] = []

        for dockerManifest in dockerManifests {
            try Task.checkCancellation()
            guard let configFile = dockerManifest.config else {
                throw Error.invalidTarball(
                    reason: "docker-archive manifest entry is missing Config"
                )
            }
            guard let layers = dockerManifest.layers else {
                throw Error.invalidTarball(
                    reason: "docker-archive manifest entry is missing Layers"
                )
            }

            let configMember = try DockerArchiveMember.config(configFile)

            guard
                let configBlob = try resolveBlob(
                    member: configMember,
                    archiveRoot: archiveRoot,
                    in: blobsDir,
                    logger: logger
                )
            else {
                throw Error.invalidTarball(
                    reason:
                        "docker-archive config \(configFile) is missing from the archive"
                )
            }

            let effectiveConfigDigest = configBlob.digest
            let configSize = configBlob.size
            let importedConfigPath = blobsDir.appendingPathComponent(
                effectiveConfigDigest
            )
            let imageConfig: DockerArchiveImagePlatform
            do {
                imageConfig = try imagePlatform(
                    fromConfigAt: importedConfigPath
                )
            } catch let error as BoundedFileReadError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Error.invalidTarball(
                    reason:
                        "docker-archive config \(configFile) is not a valid image config"
                )
            }
            guard let rootFS = imageConfig.rootFS else {
                throw Error.invalidTarball(
                    reason:
                        "docker-archive config \(configFile) is missing rootfs"
                )
            }
            guard rootFS.type == "layers", let rawDiffIDs = rootFS.diffIDs else {
                throw Error.invalidTarball(
                    reason:
                        "docker-archive config \(configFile) has a malformed rootfs"
                )
            }
            let expectedDiffIDs = try rawDiffIDs.enumerated().map {
                try Task.checkCancellation()
                return try validatedDockerArchiveDiffID(
                    $0.element,
                    configFile: configFile,
                    index: $0.offset
                )
            }
            guard expectedDiffIDs.count == layers.count else {
                throw Error.invalidTarball(
                    reason:
                        "docker-archive config \(configFile) has \(expectedDiffIDs.count) rootfs diff_id(s), but manifest.json lists \(layers.count) layer(s)"
                )
            }
            let importedPlatform = platformDictionary(from: imageConfig)

            var layerDescriptors: [[String: Any]] = []

            for (layerIndex, layer) in layers.enumerated() {
                let layerMember = try DockerArchiveMember.layer(layer)

                guard
                    let layerBlob = try resolveBlob(
                        member: layerMember,
                        archiveRoot: archiveRoot,
                        in: blobsDir,
                        logger: logger
                    )
                else {
                    throw Error.invalidTarball(
                        reason:
                            "docker-archive layer \(layer) is missing from the archive"
                    )
                }
                let effectiveLayerDigest = layerBlob.digest
                let layerSize = layerBlob.size
                let importedLayerPath = blobsDir.appendingPathComponent(
                    effectiveLayerDigest
                )
                let mediaType = try ociLayerMediaType(
                    forDockerArchiveLayerAt: importedLayerPath
                )
                try validateDockerArchiveLayer(
                    at: importedLayerPath,
                    archiveMember: layer,
                    expectedDiffID: expectedDiffIDs[layerIndex],
                    temporaryParent: ociLayoutPath
                )
                layerDescriptors.append([
                    "mediaType": mediaType,
                    "digest": "sha256:\(effectiveLayerDigest)",
                    "size": layerSize,
                ])
            }

            let manifest: [String: Any] = [
                "schemaVersion": 2,
                "config": [
                    "mediaType": "application/vnd.oci.image.config.v1+json",
                    "digest": "sha256:\(effectiveConfigDigest)",
                    "size": configSize,
                ],
                "layers": layerDescriptors,
            ]

            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            )
            let manifestDigest = manifestData.sha256Hex()
            let manifestPath = blobsDir.appendingPathComponent(manifestDigest)
            try manifestData.write(to: manifestPath)

            var manifestDescriptor: [String: Any] = [
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": "sha256:\(manifestDigest)",
                "size": manifestData.count,
            ]

            if let importedPlatform {
                manifestDescriptor["platform"] = importedPlatform
            }

            let repoTags = dockerManifest.repoTags ?? []
            if repoTags.isEmpty {
                indexManifests.append(manifestDescriptor)
            } else {
                // A single docker-archive manifest may own several tags. OCI
                // stores a reference on each top-level descriptor, so emit
                // one descriptor per tag instead of silently keeping only
                // the first RepoTags entry.
                for repoTag in repoTags {
                    var taggedDescriptor = manifestDescriptor
                    taggedDescriptor["annotations"] = [
                        "org.opencontainers.image.ref.name": repoTag
                    ]
                    indexManifests.append(taggedDescriptor)
                }
                loadedImages.append(contentsOf: repoTags)
            }
        }

        let index: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": indexManifests,
        ]

        let indexData = try JSONSerialization.data(
            withJSONObject: index,
            options: [.prettyPrinted, .sortedKeys]
        )
        try indexData.write(to: ociLayoutPath.appendingPathComponent("index.json"))

        logger.debug("Created OCI layout at \(ociLayoutPath.path)")
        logger.info("Index contains \(indexManifests.count) manifest(s)")

        if let indexString = String(data: indexData, encoding: .utf8) {
            logger.debug("Index JSON: \(indexString)")
        }

        return loadedImages
    }

    private static func validateDockerArchiveRepoTags(
        _ repoTags: [String]
    ) throws {
        for repoTag in repoTags {
            try Task.checkCancellation()
            do {
                let reference = try Reference.parse(repoTag)
                guard reference.tag != nil, reference.digest == nil else {
                    throw Error.invalidTarball(
                        reason:
                            "docker-archive RepoTag must be a tagged image name: \(repoTag)"
                    )
                }
            } catch let error as Error {
                throw error
            } catch {
                throw Error.invalidTarball(
                    reason: "invalid docker-archive RepoTag: \(repoTag)"
                )
            }
        }
    }

    private struct DockerArchiveRootFS: Decodable {
        let type: String?
        let diffIDs: [String]?

        enum CodingKeys: String, CodingKey {
            case type
            case diffIDs = "diff_ids"
        }
    }

    private struct DockerArchiveImagePlatform: Decodable {
        let architecture: String?
        let os: String?
        let variant: String?
        let osVersion: String?
        let osFeatures: [String]?
        let rootFS: DockerArchiveRootFS?

        enum CodingKeys: String, CodingKey {
            case architecture
            case os
            case variant
            case osVersion = "os.version"
            case osFeatures = "os.features"
            case rootFS = "rootfs"
        }
    }

    /// Legacy docker-archive has no platform field in `manifest.json`; the
    /// architecture lives in the referenced image config. Carry it onto the OCI
    /// descriptor so several entries sharing one tag can be reconstructed as a
    /// coherent multi-platform index during load.
    private static func platformDictionary(
        from config: DockerArchiveImagePlatform
    ) -> [String: Any]? {
        guard let architecture = config.architecture, !architecture.isEmpty,
            let os = config.os, !os.isEmpty
        else {
            return nil
        }

        var platform: [String: Any] = [
            "architecture": architecture,
            "os": os,
        ]
        if let variant = config.variant, !variant.isEmpty {
            platform["variant"] = variant
        }
        if let osVersion = config.osVersion, !osVersion.isEmpty {
            platform["os.version"] = osVersion
        }
        if let osFeatures = config.osFeatures, !osFeatures.isEmpty {
            platform["os.features"] = osFeatures
        }
        return platform
    }

    private static func imagePlatform(
        fromConfigAt configURL: URL
    ) throws -> DockerArchiveImagePlatform {
        let configData = try BoundedFileReader.readImageMetadata(
            relativePath: configURL.lastPathComponent,
            under: configURL.deletingLastPathComponent()
        )
        return try JSONDecoder().decode(
            DockerArchiveImagePlatform.self,
            from: configData
        )
    }

    private static func validatedDockerArchiveDiffID(
        _ value: String,
        configFile: String,
        index: Int
    ) throws -> String {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else {
            throw Error.invalidTarball(
                reason:
                    "docker-archive config \(configFile) has a non-sha256 rootfs diff_id at index \(index)"
            )
        }
        let encoded = value.dropFirst(prefix.count)
        guard encoded.utf8.count == 64,
            encoded.utf8.allSatisfy({ byte in
                (byte >= Character("0").asciiValue!
                    && byte <= Character("9").asciiValue!)
                    || (byte >= Character("a").asciiValue!
                        && byte <= Character("f").asciiValue!)
                    || (byte >= Character("A").asciiValue!
                        && byte <= Character("F").asciiValue!)
            })
        else {
            throw Error.invalidTarball(
                reason:
                    "docker-archive config \(configFile) has a malformed rootfs diff_id at index \(index)"
            )
        }
        return prefix + encoded.lowercased()
    }

    private static func validateDockerArchiveLayer(
        at layerURL: URL,
        archiveMember: String,
        expectedDiffID: String,
        temporaryParent: URL
    ) throws {
        let prepared = try prepareImportSource(
            at: layerURL,
            temporaryParent: temporaryParent,
            maxExpandedLayerSize: maxExpandedLoadLayerSize
        )
        defer { prepared.cleanUp() }

        do {
            try rejectForeignFormat(at: prepared.tarForValidation)
            try validateTar(
                at: prepared.tarForValidation,
                maxExpandedLayerSize: maxExpandedLoadLayerSize,
                maxEntries: maxImportTarEntries
            )
        } catch Error.invalidTarball(let reason) {
            throw Error.invalidTarball(
                reason:
                    "invalid docker-archive layer \(archiveMember): \(reason)"
            )
        }
        try Task.checkCancellation()
        let actualDigest =
            try prepared.exactDiffID
            ?? FileHashing.sha256OfFile(
                at: prepared.tarForValidation
            ).digest
        let actualDiffID = "sha256:\(actualDigest)"
        guard actualDiffID == expectedDiffID else {
            throw Error.invalidTarball(
                reason:
                    "docker-archive layer \(archiveMember) has diff_id \(actualDiffID), expected \(expectedDiffID)"
            )
        }
    }

    /// Docker's archive loader detects compression from the layer bytes. OCI
    /// descriptors do not: the media type must match the stored blob or the
    /// runtime will try the wrong decompressor when the image is unpacked.
    private static func ociLayerMediaType(
        forDockerArchiveLayerAt layerURL: URL
    ) throws -> String {
        switch try classifyLayerSource(at: layerURL) {
        case .gzip:
            return MediaTypes.imageLayerGzip
        case .zstd:
            return MediaTypes.imageLayerZstd
        case .plainOrUnknown:
            return MediaTypes.imageLayer
        case .bzip2, .xz:
            throw Error.invalidTarball(
                reason:
                    "docker-archive layers compressed with bzip2/xz cannot be represented by an OCI layer media type"
            )
        case .foreignFormat(let format):
            throw Error.invalidTarball(
                reason: "\(format) is not a supported docker-archive layer format"
            )
        }
    }

    /// Builds a single-layer OCI image layout from an on-disk tar (the raw
    /// `docker import fromSrc=-` request body). Mirrors `convertDockerTarToOCI`'s
    /// digest/blob/manifest/index construction, but for a synthesized image
    /// rather than one converted from an existing docker-archive.
    ///
    /// A gzip/zstd-compressed body (detected by magic bytes) is stored as-is
    /// with the matching layer media type. A plain, bzip2, or xz tar is stored
    /// as gzip (moby never stores an uncompressed/bzip2/xz layer). For every
    /// codec, diff_id is the digest of the exact raw decompressed tar stream —
    /// including headers, PAX records, and padding — matching Docker rather
    /// than hashing a lossy entry-level reserialization.
    ///
    /// Returns both content identities (without `sha256:` prefixes). Apple's
    /// loader roots the manifest in an index, while Docker reports the config
    /// digest as the local image ID.
    static func buildSingleLayerOCILayout(
        tarPath: URL,
        ociLayoutPath: URL,
        platform: Platform,
        config: SynthesizedImageConfig,
        message: String?,
        reference: String?,
        logger: Logger,
        maxExpandedLayerSize: Int = ContainerImageUtility.maxExpandedLayerSize,
        maxTarEntries: Int = ContainerImageUtility.maxImportTarEntries
    ) throws -> SynthesizedLayoutIdentity {
        guard maxTarEntries >= 0 else {
            throw Error.invalidTarball(reason: "tar entry limit cannot be negative")
        }
        try FileManager.default.createDirectory(
            at: ociLayoutPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let preparedSource = try prepareImportSource(
            at: tarPath,
            temporaryParent: ociLayoutPath,
            maxExpandedLayerSize: maxExpandedLayerSize
        )
        defer { preparedSource.cleanUp() }

        try rejectForeignFormat(at: preparedSource.tarForValidation)
        try validateTar(
            at: preparedSource.tarForValidation,
            maxExpandedLayerSize: maxExpandedLayerSize,
            maxEntries: maxTarEntries
        )

        let blobsDir = ociLayoutPath.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let ociLayout = "{\"imageLayoutVersion\": \"1.0.0\"}"
        try ociLayout.write(to: ociLayoutPath.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)

        let layer = try writeImportedLayerBlob(
            tarPath: tarPath,
            into: blobsDir,
            preparedSource: preparedSource
        )

        let createdAt = ISO8601DateFormatter().string(from: Date())
        var imageConfigDict: [String: Any] = [
            "created": createdAt,
            "architecture": platform.architecture,
            "os": platform.os,
            "config": config.toDict(),
            "rootfs": [
                "type": "layers",
                "diff_ids": ["sha256:\(layer.diffID)"],
            ],
            "history": [
                [
                    "created": createdAt,
                    "comment": message ?? "",
                ]
            ],
        ]
        if let variant = platform.variant {
            imageConfigDict["variant"] = variant
        }

        let configData = try JSONSerialization.data(
            withJSONObject: imageConfigDict,
            options: [.sortedKeys]
        )
        let configDigest = configData.sha256Hex()
        try configData.write(to: blobsDir.appendingPathComponent(configDigest))

        let manifest: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": [
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": "sha256:\(configDigest)",
                "size": configData.count,
            ],
            "layers": [
                [
                    "mediaType": layer.mediaType,
                    "digest": "sha256:\(layer.digest)",
                    "size": layer.size,
                ]
            ],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        let manifestDigest = manifestData.sha256Hex()
        try manifestData.write(to: blobsDir.appendingPathComponent(manifestDigest))

        var manifestDescriptor: [String: Any] = [
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": "sha256:\(manifestDigest)",
            "size": manifestData.count,
        ]
        if let reference {
            manifestDescriptor["annotations"] = ["org.opencontainers.image.ref.name": reference]
        }

        let index: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": [manifestDescriptor],
        ]
        let indexData = try JSONSerialization.data(
            withJSONObject: index,
            options: [.prettyPrinted, .sortedKeys]
        )
        try indexData.write(to: ociLayoutPath.appendingPathComponent("index.json"))

        logger.info("Synthesized single-layer OCI image sha256:\(manifestDigest) from an imported tarball")

        return SynthesizedLayoutIdentity(
            manifestDigest: manifestDigest,
            configDigest: configDigest
        )
    }

    private struct PreparedImportSource {
        let source: LayerSource
        let tarForValidation: URL
        let exactDiffID: String?
        let temporaryDirectory: URL?

        func cleanUp() {
            guard let temporaryDirectory else { return }
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    /// Expand compressed input exactly once into a private, bounded staging
    /// file. The same bytes are tar-validated, hashed for the OCI diffID, and
    /// (for bzip2/xz) fed to the gzip encoder. This prevents each independent
    /// operation from re-expanding an attacker-controlled stream and avoids
    /// ContainerizationArchive 0.40.1's unbounded zstd temporary-file path.
    private static func prepareImportSource(
        at source: URL,
        temporaryParent: URL,
        maxExpandedLayerSize: Int
    ) throws -> PreparedImportSource {
        let layerSource = try classifyLayerSource(at: source)
        guard
            layerSource == .gzip || layerSource == .bzip2
                || layerSource == .xz || layerSource == .zstd
        else {
            return PreparedImportSource(
                source: layerSource,
                tarForValidation: source,
                exactDiffID: nil,
                temporaryDirectory: nil
            )
        }

        let temporaryDirectory =
            temporaryParent
            .appendingPathComponent(
                "glassdock-compressed-import-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        let expandedTar = temporaryDirectory.appendingPathComponent(
            "layer.tar",
            isDirectory: false
        )
        let expandedBytes: Int64
        do {
            switch layerSource {
            case .gzip:
                expandedBytes = try FilteredStreamDecoder.decompress(
                    source: source,
                    destination: expandedTar,
                    compression: .gzip,
                    maxBytes: Int64(maxExpandedLayerSize)
                )
            case .bzip2:
                expandedBytes = try FilteredStreamDecoder.decompress(
                    source: source,
                    destination: expandedTar,
                    compression: .bzip2,
                    maxBytes: Int64(maxExpandedLayerSize)
                )
            case .xz:
                expandedBytes = try FilteredStreamDecoder.decompress(
                    source: source,
                    destination: expandedTar,
                    compression: .xz,
                    maxBytes: Int64(maxExpandedLayerSize)
                )
            case .zstd:
                expandedBytes = try ZstdStreamDecoder.decompress(
                    source: source,
                    destination: expandedTar,
                    maxBytes: Int64(maxExpandedLayerSize)
                )
            case .plainOrUnknown, .foreignFormat:
                preconditionFailure("uncompressed sources do not need staging")
            }
        } catch FilteredStreamDecoder.Error.exceedsCap,
            ZstdStreamDecoder.Error.exceedsCap
        {
            throw Error.invalidTarball(
                reason:
                    "decompressed layer exceeds the \(maxExpandedLayerSize)-byte limit"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.invalidTarball(
                reason: "failed to decompress compressed layer"
            )
        }

        try Task.checkCancellation()
        let expanded = try FileHashing.sha256OfFile(at: expandedTar)
        guard expanded.size == expandedBytes else {
            throw Error.invalidTarball(
                reason: "compressed layer changed while being prepared"
            )
        }

        completed = true
        return PreparedImportSource(
            source: layerSource,
            tarForValidation: expandedTar,
            exactDiffID: expanded.digest,
            temporaryDirectory: temporaryDirectory
        )
    }

    /// moby's own `docker import` only ever decompresses via a compression-filter
    /// detector (gzip/bzip2/xz/zstd), never a general archive-format detector —
    /// so a zip/7z/rar/etc. body isn't "unwrapped" by it either; it just fails
    /// tar parsing downstream. `ArchiveReader(file:)` is broader (it recognizes
    /// every libarchive container format, not just tar), so without this check
    /// those foreign formats would pass structural validation here and then get
    /// hashed as raw bytes in `writeImportedLayerBlob`, silently producing a
    /// corrupt, unrunnable image instead of the rejection moby would also reach.
    private enum LayerSource: Equatable {
        case gzip
        case zstd
        case bzip2
        case xz
        case plainOrUnknown
        case foreignFormat(String)
    }

    private static func classifyLayerSource(at tarPath: URL) throws -> LayerSource {
        let magic = try readMagic(at: tarPath, length: 8)
        if magic.starts(with: [0x1f, 0x8b]) { return .gzip }
        if magic.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) { return .zstd }
        if magic.starts(with: [0x42, 0x5a, 0x68]) { return .bzip2 }
        if magic.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return .xz }
        if magic.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return .foreignFormat("zip") }
        if magic.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) { return .foreignFormat("7z") }
        if magic.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) { return .foreignFormat("rar") }
        if magic.starts(with: Array("!<arch>\n".utf8)) { return .foreignFormat("ar") }
        if let leading6 = String(data: magic.prefix(6), encoding: .ascii), ["070701", "070702", "070707"].contains(leading6) {
            return .foreignFormat("cpio")
        }
        if try isISO9660(at: tarPath) { return .foreignFormat("iso9660") }
        return .plainOrUnknown
    }

    private static func readMagic(at tarPath: URL, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: tarPath)
        defer { try? handle.close() }
        return try handle.read(upToCount: length) ?? Data()
    }

    /// The "CD001" standard identifier sits at a fixed offset into the Primary
    /// Volume Descriptor, not at the start of the file.
    private static func isISO9660(at tarPath: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: tarPath)
        defer { try? handle.close() }
        handle.seek(toFileOffset: 32769)
        return try handle.read(upToCount: 5) == Data("CD001".utf8)
    }

    private static func rejectForeignFormat(at tarPath: URL) throws {
        let source = try classifyLayerSource(at: tarPath)
        if case .foreignFormat(let format) = source {
            throw Error.invalidTarball(reason: "\(format) is not a supported docker import source; only a tar, optionally gzip/bzip2/xz/zstd-compressed, is supported")
        }
        // The magic-byte blacklist above only catches formats libarchive itself
        // recognizes as non-tar containers; it can't cover formats moby also
        // wouldn't unwrap (mtree, xar, lha, shar, ...) or any other content that
        // merely fails to look like tar. Positively confirm the (decompressed)
        // bytes parse as one of the tar sub-formats libarchive knows about
        // before accepting it — verified against real GNU/PAX/ustar tars
        // (including a genuine `docker export` tarball) and against zip/cpio/ar
        // bodies to confirm this neither rejects a real tar nor accepts a
        // foreign one.
        let filter: Filter
        switch source {
        case .gzip: filter = .gzip
        case .zstd: filter = .zstd
        case .bzip2: filter = .bzip2
        case .xz: filter = .xz
        case .plainOrUnknown: filter = .none
        case .foreignFormat: return  // unreachable: handled above
        }
        guard try isRecognizedTarFamily(at: tarPath, filter: filter) else {
            throw Error.invalidTarball(reason: "not a supported docker import source; only a tar, optionally gzip/bzip2/xz/zstd-compressed, is supported")
        }
    }

    /// Tries every tar sub-format libarchive supports rather than pinning one:
    /// `archive_read_set_format` doesn't restrict which tar variant is actually
    /// parsed (a real GNU or PAX tar reads successfully under any of the four
    /// constants below), so the loop exists only to force header validation —
    /// something the auto-detecting reader used elsewhere never surfaces as an
    /// error even when it's parsing raw garbage. A real tar entry always has a
    /// non-empty path; garbage forced through the tar parser produces an entry
    /// with no path instead. A tar with zero entries (`tar cf x -T /dev/null`,
    /// the standard way to build a "scratch" image, and something real `docker
    /// import` accepts) cleanly hits EOF with no entry at all on every format —
    /// that has to be accepted too, so only a path-less entry counts as proof
    /// of a foreign format; a clean EOF is neutral, not a rejection.
    private static func isRecognizedTarFamily(
        at tarPath: URL,
        filter: Filter
    ) throws -> Bool {
        var attempted = false
        for format: ContainerizationArchive.Format in [.ustar, .gnutar, .pax, .paxRestricted] {
            try Task.checkCancellation()
            guard
                let reader = try? streamingTarReader(
                    at: tarPath,
                    format: format,
                    filter: filter
                )
            else { continue }
            attempted = true
            var iterator = reader.makeStreamingIterator()
            guard let (entry, _) = iterator.next() else { continue }
            guard let path = entry.path, !path.isEmpty else { return false }
            return true
        }
        return attempted
    }

    /// Rejects an empty body outright (a 0-byte "tar" would otherwise read back
    /// as zero archive entries — not an error `ArchiveReader` surfaces on its
    /// own) and confirms the remainder actually parses as an archive, so
    /// `docker import` of a non-tar or empty file fails cleanly instead of
    /// silently registering an unusable image.
    private static func validateTar(
        at tarPath: URL,
        maxExpandedLayerSize: Int,
        maxEntries: Int
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: tarPath.path)
        guard let size = attributes?[.size] as? UInt64, size > 0 else {
            throw Error.invalidTarball(reason: "empty request body")
        }

        let reader: ArchiveReader
        do {
            reader = try streamingTarReader(at: tarPath)
        } catch {
            throw Error.invalidTarball(reason: "not a valid tar archive: \(error.localizedDescription)")
        }
        do {
            var totalDecompressedBytes = 0
            func enforceCap() throws {
                guard totalDecompressedBytes <= maxExpandedLayerSize else {
                    throw Error.invalidTarball(reason: "decompressed layer exceeds the \(maxExpandedLayerSize)-byte limit")
                }
            }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            var entryCount = 0
            for (_, entryReader) in reader.makeStreamingIterator() {
                try Task.checkCancellation()
                guard entryCount < maxEntries else {
                    throw Error.invalidTarball(
                        reason:
                            "tar archive exceeds the \(maxEntries)-entry limit"
                    )
                }
                entryCount += 1
                totalDecompressedBytes += tarBlockSize
                try enforceCap()
                var entryContentBytes = 0
                while true {
                    try Task.checkCancellation()
                    let read = buffer.withUnsafeMutableBufferPointer { entryReader.read($0.baseAddress!, maxLength: $0.count) }
                    guard read > 0 else {
                        if read < 0 {
                            throw Error.invalidTarball(reason: "not a valid tar archive")
                        }
                        break
                    }
                    entryContentBytes += read
                    totalDecompressedBytes += read
                    try enforceCap()
                }
                totalDecompressedBytes += tarBlockPadding(forContentSize: entryContentBytes)
                try enforceCap()
            }
        } catch let error as Error {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.invalidTarball(reason: "not a valid tar archive: \(error.localizedDescription)")
        }
    }

    /// The URL-based `ArchiveReader` initializers in ContainerizationArchive
    /// 0.40.1 probe zstd by expanding it to an unbounded temporary file. Use
    /// the public FileHandle initializer for the formats system libarchive can
    /// stream. Zstd is bounded and staged by `prepareImportSource` before it
    /// reaches this helper.
    private static func streamingTarReader(
        at source: URL,
        format: ContainerizationArchive.Format = .paxRestricted,
        filter explicitFilter: Filter? = nil
    ) throws -> ArchiveReader {
        let filter: Filter
        if let explicitFilter {
            filter = explicitFilter
        } else {
            switch try classifyLayerSource(at: source) {
            case .gzip: filter = .gzip
            case .bzip2: filter = .bzip2
            case .xz: filter = .xz
            case .plainOrUnknown: filter = .none
            case .zstd:
                throw Error.invalidTarball(
                    reason: "zstd import source was not prepared"
                )
            case .foreignFormat(let format):
                throw Error.invalidTarball(
                    reason:
                        "\(format) is not a supported docker import source; only a tar, optionally gzip/bzip2/xz/zstd-compressed, is supported"
                )
            }
        }

        guard filter != .zstd else {
            throw Error.invalidTarball(
                reason: "zstd import source was not prepared"
            )
        }

        let handle = try FileHandle(forReadingFrom: source)
        do {
            return try ArchiveReader(
                format: format,
                filter: filter,
                fileHandle: handle
            )
        } catch {
            try? handle.close()
            throw error
        }
    }

    private struct ImportedLayerBlob {
        let digest: String
        let size: Int
        let diffID: String
        let mediaType: String
    }

    private static func writeImportedLayerBlob(
        tarPath: URL,
        into blobsDir: URL,
        preparedSource: PreparedImportSource
    ) throws -> ImportedLayerBlob {
        switch preparedSource.source {
        case .gzip:
            // Stored unchanged from the request body. Its exact decompressed
            // tar digest was computed from the bounded staging file.
            let (digest, size) = try FileHashing.sha256OfFile(at: tarPath)
            guard let diffID = preparedSource.exactDiffID else {
                throw Error.invalidTarball(
                    reason: "gzip layer was not prepared for import"
                )
            }
            let destination = blobsDir.appendingPathComponent(digest)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: tarPath, to: destination)
            }
            return ImportedLayerBlob(
                digest: digest, size: size, diffID: diffID,
                mediaType: "application/vnd.oci.image.layer.v1.tar+gzip")

        case .zstd:
            // `prepareImportSource` already expanded this stream once under the
            // cap. Reuse that exact raw-byte digest rather than decoding a
            // second time; the stored blob is still the original zstd bytes.
            let (digest, size) = try FileHashing.sha256OfFile(at: tarPath)
            guard let diffID = preparedSource.exactDiffID else {
                throw Error.invalidTarball(
                    reason: "zstd layer was not prepared for import"
                )
            }
            let destination = blobsDir.appendingPathComponent(digest)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: tarPath, to: destination)
            }
            return ImportedLayerBlob(
                digest: digest, size: size, diffID: diffID,
                mediaType: "application/vnd.oci.image.layer.v1.tar+zstd")

        case .plainOrUnknown:
            return try gzipCompressAndStore(plainTarPath: tarPath, into: blobsDir)

        case .bzip2, .xz:
            let stored = try gzipCompressAndStore(
                plainTarPath: preparedSource.tarForValidation,
                into: blobsDir
            )
            guard stored.diffID == preparedSource.exactDiffID else {
                throw Error.invalidTarball(
                    reason: "compressed layer changed while being stored"
                )
            }
            return stored

        case .foreignFormat(let format):
            throw Error.invalidTarball(reason: "\(format) is not a supported docker import source; only a tar, optionally gzip/bzip2/xz/zstd-compressed, is supported")
        }
    }

    /// moby's `docker import` never stores a plain uncompressed layer — an
    /// uncompressed or bzip2/xz input is always gzip-compressed before storage
    /// (daemon/containerd/image_import.go's `saveArchive`). diff_id is the
    /// pre-compression hash; the stored blob's digest is the compressed hash.
    private static func gzipCompressAndStore(plainTarPath: URL, into blobsDir: URL) throws -> ImportedLayerBlob {
        let tempDestination = blobsDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDestination) }
        let result: GzipStreamEncoder.Result
        do {
            result = try GzipStreamEncoder.compressFile(at: plainTarPath, to: tempDestination)
        } catch {
            throw Error.invalidTarball(reason: "failed to gzip-compress layer")
        }
        try moveBlob(from: tempDestination, toDigest: result.compressedDigest, in: blobsDir)
        return ImportedLayerBlob(
            digest: result.compressedDigest, size: result.compressedSize, diffID: result.uncompressedDigest,
            mediaType: "application/vnd.oci.image.layer.v1.tar+gzip")
    }

    private struct ResolvedDockerArchiveBlob {
        let digest: String
        let size: Int
    }

    private enum DockerArchiveMember {
        case config(digest: String, filename: String)
        case layer(digest: String, directory: String)

        var claimedDigest: String {
            switch self {
            case .config(let digest, _), .layer(let digest, _): digest
            }
        }

        var components: [String] {
            switch self {
            case .config(_, let filename): [filename]
            case .layer(_, let directory): [directory, "layer.tar"]
            }
        }

        static func config(_ value: String) throws -> DockerArchiveMember {
            let suffix = ".json"
            guard value.hasSuffix(suffix) else {
                throw invalidPath(value)
            }
            let digest = String(value.dropLast(suffix.count))
            guard isCanonicalSHA256Hex(digest), value == "\(digest).json" else {
                throw invalidPath(value)
            }
            return .config(digest: digest, filename: value)
        }

        static func layer(_ value: String) throws -> DockerArchiveMember {
            let components = value.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard components.count == 2,
                components[1] == "layer.tar"
            else {
                throw invalidPath(value)
            }
            let digest = String(components[0])
            guard isCanonicalSHA256Hex(digest),
                value == "\(digest)/layer.tar"
            else {
                throw invalidPath(value)
            }
            return .layer(digest: digest, directory: digest)
        }

        private static func isCanonicalSHA256Hex(_ value: String) -> Bool {
            let bytes = value.utf8
            guard bytes.count == 64 else { return false }
            return bytes.allSatisfy {
                ($0 >= Character("0").asciiValue!
                    && $0 <= Character("9").asciiValue!)
                    || ($0 >= Character("a").asciiValue!
                        && $0 <= Character("f").asciiValue!)
            }
        }

        private static func invalidPath(_ value: String) -> Error {
            Error.invalidTarball(
                reason: "invalid docker-archive member path: \(value)"
            )
        }
    }

    /// Descriptor-anchored access to the extracted legacy docker-archive.
    /// Every component is opened relative to this no-follow directory fd, and
    /// final members must be single-link regular files. This closes both URL
    /// traversal and link-swap/hardlink escapes without trusting a prior path
    /// standardization check.
    private final class DockerArchiveRoot {
        private let descriptor: Int32

        init(url: URL) throws {
            descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
            guard descriptor >= 0 else {
                throw Error.invalidTarball(
                    reason: "docker-archive root is not a safe directory"
                )
            }
        }

        deinit {
            Darwin.close(descriptor)
        }

        func open(_ member: DockerArchiveMember) throws -> Int32? {
            try openRegularFile(components: member.components)
        }

        func readManifest(maxBytes: Int) throws -> Data? {
            guard
                let manifestDescriptor = try openRegularFile(
                    components: ["manifest.json"]
                )
            else {
                return nil
            }
            defer { Darwin.close(manifestDescriptor) }

            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        manifestDescriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
                if bytesRead < 0, errno == EINTR { continue }
                guard bytesRead >= 0 else {
                    throw Error.invalidTarball(
                        reason: "failed to read manifest.json"
                    )
                }
                guard bytesRead > 0 else { break }
                guard bytesRead <= maxBytes - result.count else {
                    throw Error.invalidTarball(
                        reason: "manifest.json exceeds the \(maxBytes)-byte limit"
                    )
                }
                result.append(contentsOf: buffer.prefix(bytesRead))
            }
            return result
        }

        private func openRegularFile(
            components: [String]
        ) throws -> Int32? {
            precondition(!components.isEmpty)
            var parentDescriptor = descriptor
            var ownedParentDescriptor: Int32?
            defer {
                if let ownedParentDescriptor {
                    Darwin.close(ownedParentDescriptor)
                }
            }

            for component in components.dropLast() {
                let childDescriptor = Darwin.openat(
                    parentDescriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        | O_NONBLOCK
                )
                if childDescriptor < 0, errno == ENOENT { return nil }
                guard childDescriptor >= 0 else {
                    throw Error.invalidTarball(
                        reason: "docker-archive member has an unsafe parent"
                    )
                }
                if let ownedParentDescriptor {
                    Darwin.close(ownedParentDescriptor)
                }
                ownedParentDescriptor = childDescriptor
                parentDescriptor = childDescriptor
            }

            let finalDescriptor = Darwin.openat(
                parentDescriptor,
                components.last!,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
            if finalDescriptor < 0, errno == ENOENT { return nil }
            guard finalDescriptor >= 0 else {
                throw Error.invalidTarball(
                    reason: "docker-archive member is not a safe file"
                )
            }

            var metadata = stat()
            guard Darwin.fstat(finalDescriptor, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFREG,
                metadata.st_nlink == 1
            else {
                Darwin.close(finalDescriptor)
                throw Error.invalidTarball(
                    reason:
                        "docker-archive member must be a single-link regular file"
                )
            }
            return finalDescriptor
        }
    }

    /// Copies a grammar-validated, no-follow docker-archive member into a
    /// private temporary blob while hashing it. Only the computed lowercase
    /// SHA-256 ever becomes a destination component; a manifest-controlled
    /// claimed digest can neither escape `blobs/sha256` nor cause the source
    /// (or an external canary reached through a link) to be moved/removed.
    private static func resolveBlob(
        member: DockerArchiveMember,
        archiveRoot: DockerArchiveRoot,
        in blobsDir: URL,
        logger: Logger
    ) throws -> ResolvedDockerArchiveBlob? {
        guard let sourceDescriptor = try archiveRoot.open(member) else {
            return nil
        }
        defer { Darwin.close(sourceDescriptor) }

        let temporaryBlob = blobsDir.appendingPathComponent(
            ".glassdock-copy-\(UUID().uuidString)"
        )
        let destinationDescriptor = Darwin.open(
            temporaryBlob.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationDescriptor >= 0 else {
            throw Error.invalidTarball(
                reason: "failed to create imported image blob"
            )
        }
        var destinationIsOpen = true
        var keepTemporaryBlob = false
        defer {
            if destinationIsOpen {
                Darwin.close(destinationDescriptor)
            }
            if !keepTemporaryBlob {
                try? FileManager.default.removeItem(at: temporaryBlob)
            }
        }

        var hasher = SHA256()
        var size = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    sourceDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if bytesRead < 0, errno == EINTR {
                continue
            }
            guard bytesRead >= 0 else {
                throw Error.invalidTarball(
                    reason: "failed to read docker-archive blob"
                )
            }
            guard bytesRead > 0 else { break }
            guard bytesRead <= Int.max - size else {
                throw Error.invalidTarball(
                    reason: "docker-archive blob is too large"
                )
            }

            try buffer.withUnsafeBytes { bytes in
                let content = UnsafeRawBufferPointer(
                    rebasing: bytes.prefix(bytesRead)
                )
                hasher.update(bufferPointer: content)
                try writeAll(
                    content,
                    to: destinationDescriptor
                )
            }
            size += bytesRead
        }

        guard Darwin.close(destinationDescriptor) == 0 else {
            destinationIsOpen = false
            throw Error.invalidTarball(
                reason: "failed to finish imported image blob"
            )
        }
        destinationIsOpen = false

        let realDigest = hasher.finalize().hexString
        if realDigest != member.claimedDigest {
            logger.warning(
                "Blob digest mismatch: expected \(member.claimedDigest), got \(realDigest)"
            )
        }
        try moveBlob(
            from: temporaryBlob,
            toDigest: realDigest,
            in: blobsDir
        )
        keepTemporaryBlob = true
        return ResolvedDockerArchiveBlob(
            digest: realDigest,
            size: size
        )
    }

    private static func writeAll(
        _ bytes: UnsafeRawBufferPointer,
        to descriptor: Int32
    ) throws {
        guard let baseAddress = bytes.baseAddress else { return }
        var written = 0
        while written < bytes.count {
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: written),
                bytes.count - written
            )
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw Error.invalidTarball(
                    reason: "failed to write imported image blob"
                )
            }
            written += result
        }
    }

    /// Relocates a blob copied under a claimed digest to its real one. The store is
    /// content-addressed, so an existing target holds identical bytes — drop the
    /// redundant copy rather than fail moving onto it.
    private static func moveBlob(from source: URL, toDigest digest: String, in blobsDir: URL) throws {
        let target = blobsDir.appendingPathComponent(digest)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: source)
        } else {
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    static func convertOCIToDockerTar(
        ociLayoutPath: URL,
        dockerFormatPath: URL,
        resolvedRefs: [String],
        logger: Logger
    ) async throws -> [[String: Any]] {
        let indexData = try BoundedFileReader.readImageMetadata(
            relativePath: "index.json",
            under: ociLayoutPath
        )
        let index = try JSONDecoder().decode(Index.self, from: indexData)

        var dockerManifests: [[String: Any]] = []
        let traversalBudget = DockerArchiveTraversalBudget()

        for (idx, descriptor) in index.manifests.enumerated() {
            let reference = idx < resolvedRefs.count ? resolvedRefs[idx] : nil
            let repoTags = dockerArchiveRepoTags(for: reference)
            dockerManifests.append(
                contentsOf: try processOCIDescriptor(
                    descriptor,
                    ociLayoutPath: ociLayoutPath,
                    dockerFormatPath: dockerFormatPath,
                    repoTags: repoTags,
                    state: DockerArchiveTraversalState(
                        budget: traversalBudget
                    ),
                    logger: logger
                )
            )
        }

        return dockerManifests
    }

    private static let maxDockerArchiveIndexDepth = 32
    private static let maxDockerArchiveDescriptorVisits = 10_000

    private struct OCIContentKey: Hashable {
        let mediaType: String
        let digest: String
    }

    private final class DockerArchiveTraversalBudget {
        private var visits = 0

        func recordVisit() throws {
            visits += 1
            guard visits <= maxDockerArchiveDescriptorVisits else {
                throw Error.invalidTarball(
                    reason:
                        "OCI image graph exceeds \(maxDockerArchiveDescriptorVisits) descriptors"
                )
            }
        }
    }

    /// The same nested index can be referenced many times in an OCI DAG. Keep
    /// traversal state per exported root/tag so shared descendants are emitted
    /// once without losing the same image under a second requested tag.
    private final class DockerArchiveTraversalState {
        let budget: DockerArchiveTraversalBudget
        var expandedIndexes: Set<OCIContentKey> = []
        var emittedManifests: Set<OCIContentKey> = []

        init(budget: DockerArchiveTraversalBudget) {
            self.budget = budget
        }
    }

    private static func processOCIDescriptor(
        _ descriptor: Descriptor,
        ociLayoutPath: URL,
        dockerFormatPath: URL,
        repoTags: [String],
        state: DockerArchiveTraversalState,
        depth: Int = 0,
        visiting: Set<String> = [],
        logger: Logger
    ) throws -> [[String: Any]] {
        try state.budget.recordVisit()
        guard depth <= maxDockerArchiveIndexDepth else {
            throw Error.invalidTarball(
                reason: "OCI image index nesting exceeds \(maxDockerArchiveIndexDepth) levels"
            )
        }

        if isIndexMediaType(descriptor.mediaType) {
            guard !isArtifactDescriptor(descriptor) else {
                logger.debug(
                    "Omitting attestation/artifact index \(descriptor.digest) from legacy docker-archive export"
                )
                return []
            }
            guard !visiting.contains(descriptor.digest) else {
                throw Error.invalidTarball(
                    reason: "OCI image index contains a cycle at \(descriptor.digest)"
                )
            }
            let contentKey = OCIContentKey(
                mediaType: descriptor.mediaType,
                digest: descriptor.digest
            )
            guard state.expandedIndexes.insert(contentKey).inserted else {
                return []
            }
            let blobData = try readOCIMetadata(
                for: descriptor.digest,
                in: ociLayoutPath
            )
            let nestedIndex = try JSONDecoder().decode(Index.self, from: blobData)
            guard !isArtifactIndex(nestedIndex) else {
                logger.debug(
                    "Omitting OCI artifact index document \(descriptor.digest) from legacy docker-archive export"
                )
                return []
            }
            logger.debug(
                "Found nested OCI index with \(nestedIndex.manifests.count) descriptor(s)"
            )
            var results: [[String: Any]] = []
            for nested in nestedIndex.manifests {
                results.append(
                    contentsOf: try processOCIDescriptor(
                        nested,
                        ociLayoutPath: ociLayoutPath,
                        dockerFormatPath: dockerFormatPath,
                        repoTags: repoTags,
                        state: state,
                        depth: depth + 1,
                        visiting: visiting.union([descriptor.digest]),
                        logger: logger
                    )
                )
            }
            return results
        }

        guard isManifestMediaType(descriptor.mediaType) else {
            logger.warning(
                "Skipping descriptor with unsupported mediaType: \(descriptor.mediaType)"
            )
            return []
        }
        let contentKey = OCIContentKey(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest
        )
        guard !state.emittedManifests.contains(contentKey) else {
            return []
        }
        guard
            let manifest = try processOCIManifest(
                descriptor: descriptor,
                ociLayoutPath: ociLayoutPath,
                dockerFormatPath: dockerFormatPath,
                repoTags: repoTags,
                logger: logger
            )
        else {
            return []
        }
        state.emittedManifests.insert(contentKey)
        return [manifest]
    }

    private static func processOCIManifest(
        descriptor: Descriptor,
        ociLayoutPath: URL,
        dockerFormatPath: URL,
        repoTags: [String],
        logger: Logger
    ) throws -> [String: Any]? {
        let manifestData = try readOCIMetadata(
            for: descriptor.digest,
            in: ociLayoutPath
        )
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)

        guard !isArtifact(descriptor: descriptor, manifest: manifest) else {
            logger.debug(
                "Omitting OCI attestation/artifact \(descriptor.digest) from legacy docker-archive export"
            )
            return nil
        }

        let configDigest = try digestComponents(manifest.config.digest).value
        let configFileName = "\(configDigest).json"
        let configSrcPath = try blobURL(
            for: manifest.config.digest,
            in: ociLayoutPath
        )
        let configPlatform = try imagePlatform(
            fromConfigDigest: manifest.config.digest,
            in: ociLayoutPath
        )
        guard configPlatform.architecture != "unknown",
            configPlatform.os != "unknown"
        else {
            logger.debug(
                "Omitting unknown-platform OCI artifact \(descriptor.digest) from legacy docker-archive export"
            )
            return nil
        }
        let configDstPath = dockerFormatPath.appendingPathComponent(configFileName)

        if !FileManager.default.fileExists(atPath: configDstPath.path) {
            try FileManager.default.copyItem(at: configSrcPath, to: configDstPath)
        }

        var layers: [String] = []
        for layer in manifest.layers {
            let layerDigest = try digestComponents(layer.digest).value
            let layerFileName = "\(layerDigest)/layer.tar"
            let layerDir = dockerFormatPath.appendingPathComponent(layerDigest)

            if !FileManager.default.fileExists(atPath: layerDir.path) {
                try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)

                let layerSrcPath = try blobURL(
                    for: layer.digest,
                    in: ociLayoutPath
                )
                let layerDstPath = layerDir.appendingPathComponent("layer.tar")
                try FileManager.default.copyItem(at: layerSrcPath, to: layerDstPath)
            }

            layers.append(layerFileName)
        }

        return [
            "Config": configFileName,
            "RepoTags": repoTags,
            "Layers": layers,
        ]
    }

    private static func dockerArchiveRepoTags(for reference: String?) -> [String] {
        guard let reference, !reference.isEmpty,
            !DockerImageReferenceSemantics.isInternalReference(reference),
            reference.wholeMatch(
                of: /[a-z0-9]+:[a-fA-F0-9]{32,}/
            ) == nil,
            let parsed = try? Reference.parse(reference),
            parsed.digest == nil,
            parsed.tag != nil
        else {
            return []
        }
        return [reference]
    }

    private static func isArtifact(
        descriptor: Descriptor,
        manifest: Manifest
    ) -> Bool {
        if isArtifactDescriptor(descriptor) || manifest.artifactType != nil
            || manifest.subject != nil
        {
            return true
        }
        guard let platform = descriptor.platform else { return false }
        return platform.os == "unknown"
            || platform.architecture == "unknown"
    }

    private static func isArtifactDescriptor(_ descriptor: Descriptor) -> Bool {
        if isAttestationDescriptor(descriptor)
            || descriptor.artifactType != nil
        {
            return true
        }
        guard let platform = descriptor.platform else { return false }
        return platform.os == "unknown"
            || platform.architecture == "unknown"
    }

    private static func isArtifactIndex(_ index: Index) -> Bool {
        index.artifactType != nil || index.subject != nil
            || index.annotations?["vnd.docker.reference.type"]
                == "attestation-manifest"
    }

    private static func isAttestationDescriptor(_ descriptor: Descriptor) -> Bool {
        descriptor.annotations?["vnd.docker.reference.type"]
            == "attestation-manifest"
    }

    private static func isIndexMediaType(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.index
            || mediaType == MediaTypes.dockerManifestList
    }

    private static func isManifestMediaType(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.imageManifest
            || mediaType == MediaTypes.dockerManifest
    }

    private static func digestComponents(
        _ digest: String
    ) throws -> (algorithm: String, value: String) {
        guard
            digest.wholeMatch(
                of: /[a-z0-9]+:[a-fA-F0-9]{32,}/
            ) != nil
        else {
            throw Error.invalidTarball(
                reason: "invalid OCI content digest: \(digest)"
            )
        }
        let parts = digest.split(separator: ":", maxSplits: 1)
        return (String(parts[0]), String(parts[1]))
    }

    private static func blobURL(
        for digest: String,
        in ociLayoutPath: URL
    ) throws -> URL {
        let components = try digestComponents(digest)
        let layoutRoot = ociLayoutPath
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let blobsRoot =
            layoutRoot
            .appendingPathComponent("blobs")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard blobsRoot.path.hasPrefix(layoutRoot.path + "/") else {
            throw Error.invalidTarball(
                reason: "OCI blob directory escapes the image layout"
            )
        }
        let url =
            blobsRoot
            .appendingPathComponent(components.algorithm)
            .appendingPathComponent(components.value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.path.hasPrefix(blobsRoot.path + "/") else {
            throw Error.invalidTarball(
                reason: "OCI content digest escapes the blob directory"
            )
        }
        return url
    }

    private static func readOCIMetadata(
        for digest: String,
        in ociLayoutPath: URL
    ) throws -> Data {
        let components = try digestComponents(digest)
        return try BoundedFileReader.readImageMetadata(
            relativePath:
                "blobs/\(components.algorithm)/\(components.value)",
            under: ociLayoutPath
        )
    }

    private static func imagePlatform(
        fromConfigDigest digest: String,
        in ociLayoutPath: URL
    ) throws -> DockerArchiveImagePlatform {
        try JSONDecoder().decode(
            DockerArchiveImagePlatform.self,
            from: readOCIMetadata(for: digest, in: ociLayoutPath)
        )
    }
}

extension Data {
    func sha256Hex() -> String {
        let hash = SHA256.hash(data: self)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
