import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging

enum ContainerImageUtility {

    enum Error: Swift.Error {
        case invalidTarball(reason: String)
    }

    /// Bounds decompressed gzip content the same way `maxImportBodySize`
    /// bounds the upload itself, so a small, extreme-ratio malicious layer
    /// can't expand past a reasonable ceiling before being rejected.
    private static let maxExpandedLayerSize = 8 * 1024 * 1024 * 1024

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
                loadedImages.append(contentsOf: dockerManifest.repoTags ?? [])
            } else {
                logger.warning("Skipping \((dockerManifest.repoTags ?? []).joined(separator: ", ")): config \(configFile) missing from archive")
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
    /// A gzip/zstd-compressed body (detected by magic bytes) is stored as-is
    /// with the matching layer media type; its diff_id is the digest of the
    /// decompressed content, matching moby's passthrough-if-already-compressed
    /// behavior. A plain tar is gzip-compressed before storage (moby never
    /// stores an uncompressed layer). bzip2/xz bodies are reserialized to a
    /// plain tar via `reserializeToPlainTar` and then gzip-compressed the same
    /// way — content-faithful (round-trip verified against symlinks,
    /// hardlinks, xattrs, and non-default permission bits), but the diff_id is
    /// computed from the reserialized pax tar rather than moby's raw
    /// decompressed byte stream, so it will not byte-match a real dockerd's
    /// diff_id for the same bzip2/xz input even though the layer content is
    /// identical.
    ///
    /// Returns the manifest digest (without the `sha256:` prefix).
    static func buildSingleLayerOCILayout(
        tarPath: URL,
        ociLayoutPath: URL,
        platform: Platform,
        config: SynthesizedImageConfig,
        message: String?,
        reference: String?,
        logger: Logger,
        maxExpandedLayerSize: Int = ContainerImageUtility.maxExpandedLayerSize
    ) throws -> String {
        try rejectForeignFormat(at: tarPath)
        try validateTar(at: tarPath, maxExpandedLayerSize: maxExpandedLayerSize)

        let blobsDir = ociLayoutPath.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let ociLayout = "{\"imageLayoutVersion\": \"1.0.0\"}"
        try ociLayout.write(to: ociLayoutPath.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)

        let layer = try writeImportedLayerBlob(tarPath: tarPath, into: blobsDir, maxExpandedLayerSize: maxExpandedLayerSize)

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
        guard isRecognizedTarFamily(at: tarPath, filter: filter) else {
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
    private static func isRecognizedTarFamily(at tarPath: URL, filter: Filter) -> Bool {
        var attempted = false
        for format: ContainerizationArchive.Format in [.ustar, .gnutar, .pax, .paxRestricted] {
            guard let reader = try? ArchiveReader(format: format, filter: filter, file: tarPath) else { continue }
            attempted = true
            var iterator = reader.makeStreamingIterator()
            guard let (entry, _) = iterator.next() else { continue }
            guard let path = entry.path, !path.isEmpty else { return false }
            return true
        }
        return attempted
    }

    /// Repackages an archive whose compression `ArchiveReader` can decompress
    /// but `DataCompression` cannot (bzip2/xz/zstd) into a canonical
    /// uncompressed tar, so the diff_id and stored blob reflect the real
    /// content instead of the still-compressed bytes.
    private static func reserializeToPlainTar(from source: URL, to destination: URL, maxExpandedLayerSize: Int) throws {
        let reader = try ArchiveReader(file: source)
        let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: destination)
        var totalDecompressedBytes = 0
        func enforceCap() throws {
            guard totalDecompressedBytes <= maxExpandedLayerSize else {
                throw Error.invalidTarball(reason: "decompressed layer exceeds the \(maxExpandedLayerSize)-byte limit")
            }
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for (entry, entryReader) in reader.makeStreamingIterator() {
            totalDecompressedBytes += tarBlockSize
            try enforceCap()
            let transaction = writer.makeTransactionWriter()
            try transaction.writeHeader(entry: entry)
            var entryContentBytes = 0
            while true {
                let read = buffer.withUnsafeMutableBufferPointer { entryReader.read($0.baseAddress!, maxLength: $0.count) }
                guard read > 0 else {
                    if read < 0 { throw Error.invalidTarball(reason: "failed to read archive entry while repackaging") }
                    break
                }
                entryContentBytes += read
                totalDecompressedBytes += read
                try enforceCap()
                try buffer.withUnsafeBytes { try transaction.writeChunk(data: UnsafeRawBufferPointer(rebasing: $0.prefix(read))) }
            }
            totalDecompressedBytes += tarBlockPadding(forContentSize: entryContentBytes)
            try enforceCap()
            try transaction.finish()
        }
        try writer.finishEncoding()
    }

    /// Rejects an empty body outright (a 0-byte "tar" would otherwise read back
    /// as zero archive entries — not an error `ArchiveReader` surfaces on its
    /// own) and confirms the remainder actually parses as an archive, so
    /// `docker import` of a non-tar or empty file fails cleanly instead of
    /// silently registering an unusable image.
    private static func validateTar(at tarPath: URL, maxExpandedLayerSize: Int) throws {
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
            var totalDecompressedBytes = 0
            func enforceCap() throws {
                guard totalDecompressedBytes <= maxExpandedLayerSize else {
                    throw Error.invalidTarball(reason: "decompressed layer exceeds the \(maxExpandedLayerSize)-byte limit")
                }
            }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            for (_, entryReader) in reader.makeStreamingIterator() {
                totalDecompressedBytes += tarBlockSize
                try enforceCap()
                var entryContentBytes = 0
                while true {
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

    private static func writeImportedLayerBlob(tarPath: URL, into blobsDir: URL, maxExpandedLayerSize: Int) throws -> ImportedLayerBlob {
        switch try classifyLayerSource(at: tarPath) {
        case .gzip:
            // Stored as-is (unchanged from the request body): copied straight
            // from `tarPath` and hashed by streaming the file in chunks. The
            // diff_id is the decompressed content's hash — decompressed via
            // `GzipStreamDecoder`, which never materializes the expanded
            // content in memory, unlike `DataCompression.gunzip()`, so a
            // small, highly-compressible malicious layer can't exhaust memory
            // before `maxExpandedLayerSize` catches it mid-stream.
            let (digest, size) = try FileHashing.sha256OfFile(at: tarPath)
            let diffID: String
            do {
                diffID = try GzipStreamDecoder.sha256OfDecompressedContent(at: tarPath, cap: maxExpandedLayerSize)
            } catch GzipStreamDecoder.Error.exceedsCap {
                throw Error.invalidTarball(reason: "decompressed layer exceeds the \(maxExpandedLayerSize)-byte limit")
            } catch {
                throw Error.invalidTarball(reason: "failed to decompress gzip layer")
            }
            let destination = blobsDir.appendingPathComponent(digest)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: tarPath, to: destination)
            }
            return ImportedLayerBlob(
                digest: digest, size: size, diffID: diffID,
                mediaType: "application/vnd.oci.image.layer.v1.tar+gzip")

        case .zstd:
            // Unlike gzip, zstd needs no in-memory pass at all: both the stored
            // blob's digest and the decompressed diff_id are computed by
            // streaming files in chunks, and storage is a plain file copy.
            let (digest, size) = try FileHashing.sha256OfFile(at: tarPath)
            let decompressedPath = try ArchiveReader.decompressZstd(tarPath)
            defer { ArchiveReader.cleanUpDecompressedZstd(decompressedPath) }
            let decompressedAttributes = try? FileManager.default.attributesOfItem(atPath: decompressedPath.path)
            guard let decompressedSize = decompressedAttributes?[.size] as? UInt64, decompressedSize <= UInt64(maxExpandedLayerSize) else {
                throw Error.invalidTarball(reason: "decompressed layer exceeds the \(maxExpandedLayerSize)-byte limit")
            }
            let (diffID, _) = try FileHashing.sha256OfFile(at: decompressedPath)
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
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let plainPath = tempDir.appendingPathComponent("layer.tar")
            try reserializeToPlainTar(from: tarPath, to: plainPath, maxExpandedLayerSize: maxExpandedLayerSize)
            return try gzipCompressAndStore(plainTarPath: plainPath, into: blobsDir)

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
        let (realDigest, size) = try FileHashing.sha256OfFile(at: destination)
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
