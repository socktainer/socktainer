import CryptoKit
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
