import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import DataCompression
import Foundation
import Logging

enum ContainerImageUtility {

    enum Error: Swift.Error {
        case invalidTarball(reason: String)
    }

    static func convertDockerTarToOCI(
        dockerFormatPath: URL,
        ociLayoutPath: URL,
        logger: Logger
    ) async throws -> [String] {
        let manifestPath = dockerFormatPath.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw Error.invalidTarball(reason: "manifest.json not found")
        }

        let manifestData = try Data(contentsOf: manifestPath)
        let dockerManifests = try JSONDecoder().decode([TarManifest].self, from: manifestData)

        let blobsDir = ociLayoutPath.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let ociLayout = "{\"imageLayoutVersion\": \"1.0.0\"}"
        try ociLayout.write(to: ociLayoutPath.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)

        var indexManifests: [[String: Any]] = []
        var loadedImages: [String] = []

        for dockerManifest in dockerManifests {
            guard let configFile = dockerManifest.config,
                let layers = dockerManifest.layers
            else {
                continue
            }

            let configDigest = configFile.replacingOccurrences(of: ".json", with: "")
            let configSrcPath = dockerFormatPath.appendingPathComponent(configFile)

            if FileManager.default.fileExists(atPath: configSrcPath.path) {
                let (effectiveConfigDigest, configSize) = try resolveBlob(from: configSrcPath, claimedDigest: configDigest, in: blobsDir, logger: logger)

                var layerDescriptors: [[String: Any]] = []

                for layer in layers {
                    let layerDigest = layer.replacingOccurrences(of: "/layer.tar", with: "")
                    let layerSrcPath = dockerFormatPath.appendingPathComponent(layer)

                    if FileManager.default.fileExists(atPath: layerSrcPath.path) {
                        let (effectiveLayerDigest, layerSize) = try resolveBlob(from: layerSrcPath, claimedDigest: layerDigest, in: blobsDir, logger: logger)
                        layerDescriptors.append([
                            "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                            "digest": "sha256:\(effectiveLayerDigest)",
                            "size": layerSize,
                        ])
                    }
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

                let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [])
                let manifestDigest = manifestData.sha256Hex()
                let manifestPath = blobsDir.appendingPathComponent(manifestDigest)
                try manifestData.write(to: manifestPath)

                var manifestDescriptor: [String: Any] = [
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "digest": "sha256:\(manifestDigest)",
                    "size": manifestData.count,
                ]

                if let repoTags = dockerManifest.repoTags, let firstTag = repoTags.first {
                    manifestDescriptor["annotations"] = [
                        "org.opencontainers.image.ref.name": firstTag
                    ]
                }

                indexManifests.append(manifestDescriptor)
            }

            for repoTag in dockerManifest.repoTags ?? [] {
                loadedImages.append(repoTag)
            }
        }

        let index: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": indexManifests,
        ]

        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted])
        try indexData.write(to: ociLayoutPath.appendingPathComponent("index.json"))

        logger.debug("Created OCI layout at \(ociLayoutPath.path)")
        logger.info("Index contains \(indexManifests.count) manifest(s)")

        if let indexString = String(data: indexData, encoding: .utf8) {
            logger.debug("Index JSON: \(indexString)")
        }

        return loadedImages
    }

    /// Builds a single-layer OCI image layout from an on-disk tar (the raw
    /// `docker import fromSrc=-` request body). Mirrors `convertDockerTarToOCI`'s
    /// digest/blob/manifest/index construction, but for a synthesized image
    /// rather than one converted from an existing docker-archive.
    ///
    /// A gzip-compressed body (detected by magic bytes) is stored as-is with the
    /// gzip layer media type; its diff_id is the digest of the decompressed
    /// content, matching moby's passthrough-if-already-compressed behavior.
    /// Anything else is treated as an uncompressed tar: the stored blob's own
    /// digest doubles as its diff_id. bzip2/xz bodies are not decompressed —
    /// they fall into the uncompressed path, so their diff_id would not match
    /// the true uncompressed content (see PR description: deferred).
    ///
    /// Returns the manifest digest (without the `sha256:` prefix).
    static func buildSingleLayerOCILayout(
        tarPath: URL,
        ociLayoutPath: URL,
        platform: Platform,
        config: SynthesizedImageConfig,
        message: String?,
        reference: String?,
        logger: Logger
    ) throws -> String {
        try rejectForeignFormat(at: tarPath)
        try validateTar(at: tarPath)

        let blobsDir = ociLayoutPath.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let ociLayout = "{\"imageLayoutVersion\": \"1.0.0\"}"
        try ociLayout.write(to: ociLayoutPath.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)

        let layer = try writeImportedLayerBlob(tarPath: tarPath, into: blobsDir)

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

        let configData = try JSONSerialization.data(withJSONObject: imageConfigDict, options: [])
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
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [])
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
        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted])
        try indexData.write(to: ociLayoutPath.appendingPathComponent("index.json"))

        logger.info("Synthesized single-layer OCI image sha256:\(manifestDigest) from an imported tarball")

        return manifestDigest
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
        case plainOrUnknown
        case reserializeRequired
        case foreignFormat(String)
    }

    private static func classifyLayerSource(at tarPath: URL) throws -> LayerSource {
        let magic = try readMagic(at: tarPath, length: 8)
        if magic.starts(with: [0x1f, 0x8b]) { return .gzip }
        if magic.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) { return .zstd }
        if magic.starts(with: [0x42, 0x5a, 0x68]) { return .reserializeRequired }  // bzip2
        if magic.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return .reserializeRequired }  // xz
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
        guard case .foreignFormat(let format) = try classifyLayerSource(at: tarPath) else { return }
        throw Error.invalidTarball(reason: "\(format) is not a supported docker import source; only a tar, optionally gzip/bzip2/xz/zstd-compressed, is supported")
    }

    /// Repackages an archive whose compression `ArchiveReader` can decompress
    /// but `DataCompression` cannot (bzip2/xz/zstd) into a canonical
    /// uncompressed tar, so the diff_id and stored blob reflect the real
    /// content instead of the still-compressed bytes.
    private static func reserializeToPlainTar(from source: URL, to destination: URL) throws {
        let reader = try ArchiveReader(file: source)
        let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: destination)
        for (entry, entryReader) in reader.makeStreamingIterator() {
            let transaction = writer.makeTransactionWriter()
            try transaction.writeHeader(entry: entry)
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let read = buffer.withUnsafeMutableBufferPointer { entryReader.read($0.baseAddress!, maxLength: $0.count) }
                guard read > 0 else {
                    if read < 0 { throw Error.invalidTarball(reason: "failed to read archive entry while repackaging") }
                    break
                }
                try buffer.withUnsafeBytes { try transaction.writeChunk(data: UnsafeRawBufferPointer(rebasing: $0.prefix(read))) }
            }
            try transaction.finish()
        }
        try writer.finishEncoding()
    }

    /// Rejects an empty body outright (a 0-byte "tar" would otherwise read back
    /// as zero archive entries — not an error `ArchiveReader` surfaces on its
    /// own) and confirms the remainder actually parses as an archive, so
    /// `docker import` of a non-tar or empty file fails cleanly instead of
    /// silently registering an unusable image.
    private static func validateTar(at tarPath: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: tarPath.path)
        guard let size = attributes?[.size] as? UInt64, size > 0 else {
            throw Error.invalidTarball(reason: "empty request body")
        }

        let reader: ArchiveReader
        do {
            reader = try ArchiveReader(file: tarPath)
        } catch {
            throw Error.invalidTarball(reason: "not a valid tar archive: \(error.localizedDescription)")
        }
        do {
            for (_, entryReader) in reader.makeStreamingIterator() {
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let read = buffer.withUnsafeMutableBufferPointer { entryReader.read($0.baseAddress!, maxLength: $0.count) }
                    guard read > 0 else {
                        if read < 0 {
                            throw Error.invalidTarball(reason: "not a valid tar archive")
                        }
                        break
                    }
                }
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidTarball(reason: "not a valid tar archive: \(error.localizedDescription)")
        }
    }

    private struct ImportedLayerBlob {
        let digest: String
        let size: Int
        let diffID: String
        let mediaType: String
    }

    private static func writeImportedLayerBlob(tarPath: URL, into blobsDir: URL) throws -> ImportedLayerBlob {
        switch try classifyLayerSource(at: tarPath) {
        case .gzip:
            let compressed = try Data(contentsOf: tarPath)
            guard let decompressed = compressed.gunzip() else {
                throw Error.invalidTarball(reason: "failed to decompress gzip layer")
            }
            let digest = compressed.sha256Hex()
            let destination = blobsDir.appendingPathComponent(digest)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try compressed.write(to: destination)
            }
            return ImportedLayerBlob(
                digest: digest, size: compressed.count, diffID: decompressed.sha256Hex(),
                mediaType: "application/vnd.oci.image.layer.v1.tar+gzip")

        case .zstd:
            let original = try Data(contentsOf: tarPath)
            let decompressedPath = try ArchiveReader.decompressZstd(tarPath)
            defer { ArchiveReader.cleanUpDecompressedZstd(decompressedPath) }
            let (diffID, _) = try sha256OfFile(at: decompressedPath)
            let digest = original.sha256Hex()
            let destination = blobsDir.appendingPathComponent(digest)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try original.write(to: destination)
            }
            return ImportedLayerBlob(
                digest: digest, size: original.count, diffID: diffID,
                mediaType: "application/vnd.oci.image.layer.v1.tar+zstd")

        case .plainOrUnknown:
            return try gzipCompressAndStore(plainTarData: try Data(contentsOf: tarPath), into: blobsDir)

        case .reserializeRequired:
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let plainPath = tempDir.appendingPathComponent("layer.tar")
            try reserializeToPlainTar(from: tarPath, to: plainPath)
            return try gzipCompressAndStore(plainTarData: try Data(contentsOf: plainPath), into: blobsDir)

        case .foreignFormat(let format):
            throw Error.invalidTarball(reason: "\(format) is not a supported docker import source; only a tar, optionally gzip/bzip2/xz/zstd-compressed, is supported")
        }
    }

    /// moby's `docker import` never stores a plain uncompressed layer — an
    /// uncompressed or bzip2/xz input is always gzip-compressed before storage
    /// (daemon/containerd/image_import.go's `saveArchive`). diff_id is the
    /// pre-compression hash; the stored blob's digest is the compressed hash.
    private static func gzipCompressAndStore(plainTarData: Data, into blobsDir: URL) throws -> ImportedLayerBlob {
        guard let compressed = plainTarData.gzip() else {
            throw Error.invalidTarball(reason: "failed to gzip-compress layer")
        }
        let digest = compressed.sha256Hex()
        let destination = blobsDir.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try compressed.write(to: destination)
        }
        return ImportedLayerBlob(
            digest: digest, size: compressed.count, diffID: plainTarData.sha256Hex(),
            mediaType: "application/vnd.oci.image.layer.v1.tar+gzip")
    }

    /// Hashes a blob in fixed-size chunks so a multi-GB layer never has to be held
    /// in memory at once. Returns the digest and byte count for its descriptor.
    private static func sha256OfFile(at url: URL) throws -> (digest: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        let digest = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        return (digest, size)
    }

    /// Copies a docker-archive blob into the content-addressed store (skipping if already
    /// present), then returns the digest it actually hashes to and its byte count —
    /// relocating it to its real digest when the claimed one is wrong, so the manifest
    /// never references a blob that was moved out from under it. Config and layer blobs
    /// share this path so the two can't drift (an earlier divergence lost the real digest).
    private static func resolveBlob(from source: URL, claimedDigest: String, in blobsDir: URL, logger: Logger) throws -> (digest: String, size: Int) {
        let destination = blobsDir.appendingPathComponent(claimedDigest)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let (realDigest, size) = try sha256OfFile(at: destination)
        guard realDigest != claimedDigest else { return (claimedDigest, size) }
        logger.warning("Blob digest mismatch: expected \(claimedDigest), got \(realDigest)")
        try moveBlob(from: destination, toDigest: realDigest, in: blobsDir)
        return (realDigest, size)
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
        let indexData = try Data(contentsOf: ociLayoutPath.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(OCILayoutIndex.self, from: indexData)

        var dockerManifests: [[String: Any]] = []

        for (idx, descriptor) in index.manifests.enumerated() {
            let descriptorDigest = descriptor.digest.replacingOccurrences(of: "sha256:", with: "")
            let blobPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(descriptorDigest)")
            let blobData = try Data(contentsOf: blobPath)

            if descriptor.mediaType == "application/vnd.oci.image.index.v1+json" {
                logger.debug("Found nested OCI index, processing manifests inside")
                let nestedIndex = try JSONDecoder().decode(OCILayoutIndex.self, from: blobData)

                for nestedDescriptor in nestedIndex.manifests {
                    if nestedDescriptor.mediaType == "application/vnd.oci.image.manifest.v1+json" {
                        let manifest = try processOCIManifest(
                            descriptor: nestedDescriptor,
                            ociLayoutPath: ociLayoutPath,
                            dockerFormatPath: dockerFormatPath,
                            repoTag: idx < resolvedRefs.count ? resolvedRefs[idx] : "unknown:latest",
                            logger: logger
                        )
                        dockerManifests.append(manifest)
                    }
                }
            } else if descriptor.mediaType == "application/vnd.oci.image.manifest.v1+json" {
                let manifest = try processOCIManifest(
                    descriptor: descriptor,
                    ociLayoutPath: ociLayoutPath,
                    dockerFormatPath: dockerFormatPath,
                    repoTag: idx < resolvedRefs.count ? resolvedRefs[idx] : "unknown:latest",
                    logger: logger
                )
                dockerManifests.append(manifest)
            } else {
                logger.warning("Skipping descriptor with unknown mediaType: \(descriptor.mediaType)")
            }
        }

        return dockerManifests
    }

    private static func processOCIManifest(
        descriptor: OCILayoutDescriptor,
        ociLayoutPath: URL,
        dockerFormatPath: URL,
        repoTag: String,
        logger: Logger
    ) throws -> [String: Any] {
        let manifestDigest = descriptor.digest.replacingOccurrences(of: "sha256:", with: "")
        let manifestPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(manifestDigest)")
        let manifestData = try Data(contentsOf: manifestPath)
        let manifest = try JSONDecoder().decode(OCILayoutManifest.self, from: manifestData)

        let configDigest = manifest.config.digest.replacingOccurrences(of: "sha256:", with: "")
        let configFileName = "\(configDigest).json"
        let configSrcPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(configDigest)")
        let configDstPath = dockerFormatPath.appendingPathComponent(configFileName)

        if !FileManager.default.fileExists(atPath: configDstPath.path) {
            try FileManager.default.copyItem(at: configSrcPath, to: configDstPath)
        }

        var layers: [String] = []
        for layer in manifest.layers {
            let layerDigest = layer.digest.replacingOccurrences(of: "sha256:", with: "")
            let layerFileName = "\(layerDigest)/layer.tar"
            let layerDir = dockerFormatPath.appendingPathComponent(layerDigest)

            if !FileManager.default.fileExists(atPath: layerDir.path) {
                try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)

                let layerSrcPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(layerDigest)")
                let layerDstPath = layerDir.appendingPathComponent("layer.tar")
                try FileManager.default.copyItem(at: layerSrcPath, to: layerDstPath)
            }

            layers.append(layerFileName)
        }

        return [
            "Config": configFileName,
            "RepoTags": [repoTag],
            "Layers": layers,
        ]
    }
}

extension Data {
    func sha256Hex() -> String {
        let hash = SHA256.hash(data: self)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
