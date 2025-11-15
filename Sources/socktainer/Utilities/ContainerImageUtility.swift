import ContainerPersistence
import CryptoKit
import Foundation
import Logging

enum ContainerImageUtility {

    enum Error: Swift.Error {
        case invalidTarball(reason: String)
    }

    static func normalizeImageReference(_ reference: String) -> String {
        guard !reference.isEmpty else { return reference }

        let components = reference.split(separator: "/", maxSplits: 1)
        if components.count > 1 {
            let firstComponent = String(components[0])
            if firstComponent.contains(".") || firstComponent.contains(":") || firstComponent == "localhost" {
                return reference
            }
        }

        let defaultRegistry = DefaultsStore.get(key: .defaultRegistryDomain)
        let defaultRepo = "library"

        if components.count == 1 {
            return "\(defaultRegistry)/\(defaultRepo)/\(reference)"
        }

        return "\(defaultRegistry)/\(reference)"
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
            let configDstPath = blobsDir.appendingPathComponent(configDigest)

            if FileManager.default.fileExists(atPath: configSrcPath.path) {
                try FileManager.default.copyItem(at: configSrcPath, to: configDstPath)

                let configData = try Data(contentsOf: configDstPath)
                let configSize = configData.count
                let configRealDigest = configData.sha256Hex()

                if configRealDigest != configDigest {
                    logger.warning("Config digest mismatch: expected \(configDigest), got \(configRealDigest)")
                    let correctPath = blobsDir.appendingPathComponent(configRealDigest)
                    try FileManager.default.moveItem(at: configDstPath, to: correctPath)
                }

                var layerDescriptors: [[String: Any]] = []

                for layer in layers {
                    let layerDigest = layer.replacingOccurrences(of: "/layer.tar", with: "")
                    let layerSrcPath = dockerFormatPath.appendingPathComponent(layer)
                    let layerDstPath = blobsDir.appendingPathComponent(layerDigest)

                    if FileManager.default.fileExists(atPath: layerSrcPath.path) {
                        try FileManager.default.copyItem(at: layerSrcPath, to: layerDstPath)

                        let layerData = try Data(contentsOf: layerDstPath)
                        let layerSize = layerData.count
                        let layerRealDigest = layerData.sha256Hex()

                        if layerRealDigest != layerDigest {
                            logger.warning("Layer digest mismatch: expected \(layerDigest), got \(layerRealDigest)")
                            let correctPath = blobsDir.appendingPathComponent(layerRealDigest)
                            try FileManager.default.moveItem(at: layerDstPath, to: correctPath)

                            layerDescriptors.append([
                                "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                                "digest": "sha256:\(layerRealDigest)",
                                "size": layerSize,
                            ])
                        } else {
                            layerDescriptors.append([
                                "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                                "digest": "sha256:\(layerDigest)",
                                "size": layerSize,
                            ])
                        }
                    }
                }

                let manifest: [String: Any] = [
                    "schemaVersion": 2,
                    "config": [
                        "mediaType": "application/vnd.oci.image.config.v1+json",
                        "digest": "sha256:\(configDigest)",
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
