import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

protocol ClientImageProtocol: Sendable {
    func list(includeSystemImages: Bool) async throws -> [ClientImage]
    func delete(id: String) async throws
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    >
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    >
    func prune(filters: [String: [String]], logger: Logger) async throws -> (deletedImages: [String], spaceReclaimed: Int64)
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String]
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL
}

extension ClientImageProtocol {
    func list() async throws -> [ClientImage] {
        try await list(includeSystemImages: false)
    }
}

enum ClientImageError: Error {
    case notFound(id: String)
}

struct ClientImageService: ClientImageProtocol {
    private let containerSystemConfig: ContainerSystemConfig

    init(containerSystemConfig: ContainerSystemConfig) {
        self.containerSystemConfig = containerSystemConfig
    }

    // Workaround for narrowing an unspecified push from all platforms to a single platform available.
    // This avoids container push failures caused by missing blobs for non local platforms.
    private func resolvedPushPlatform(for image: ClientImage, requestedPlatform: Platform?, logger: Logger) async throws -> Platform? {
        guard requestedPlatform == nil else {
            return requestedPlatform
        }

        let manifests = try await image.index().manifests
        var availablePlatforms: [Platform] = []

        for descriptor in manifests {
            if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                referenceType == "attestation-manifest"
            {
                continue
            }

            guard let platform = descriptor.platform else {
                continue
            }

            do {
                _ = try await image.manifest(for: platform)
                availablePlatforms.append(platform)
            } catch {
                logger.debug("Skipping unavailable platform \(platform.description) for push of \(image.reference): \(error)")
            }
        }

        if availablePlatforms.count == 1 {
            return availablePlatforms[0]
        }

        return nil
    }

    func list(includeSystemImages: Bool = false) async throws -> [ClientImage] {
        let allImages = try await ClientImage.list()
        guard !includeSystemImages else {
            return allImages
        }
        // filter out infra images
        // also filter images based on digests
        let filteredImages = allImages.filter { img in
            let ref = img.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDigest = ref.contains("@sha256:")
            let isInfra = Utility.isInfraImage(name: ref, builderImage: containerSystemConfig.build.image, initImage: containerSystemConfig.vminit.image)
            return isDigest || !isInfra
        }
        return filteredImages
    }

    func delete(id: String) async throws {
        do {
            _ = try await ClientImage.get(reference: id, containerSystemConfig: containerSystemConfig)
        } catch {
            // Handle specific error if needed
            throw ClientImageError.notFound(id: id)
        }
        try await ClientImage.delete(reference: id, garbageCollect: false)
    }

    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    > {
        let reference = try {
            guard let tag, !tag.isEmpty else {
                return try ClientImage.normalizeReference(image, containerSystemConfig: containerSystemConfig)
            }

            let parsedReference = try Reference.parse(image)
            let updatedReference: Reference
            if tag.starts(with: "sha256:") {
                updatedReference = try parsedReference.withDigest(tag)
            } else {
                updatedReference = try parsedReference.withTag(tag)
            }
            return try ClientImage.normalizeReference(updatedReference.description, containerSystemConfig: containerSystemConfig)
        }()

        logger.info("Pulling image reference: \(reference)")

        return AsyncThrowingStream { continuation in
            logger.info("Starting to pull image \(reference) for platform \(platform.description)")
            continuation.yield("Trying to pull \(reference)")
            Task {
                do {
                    let image = try await ClientImage.pull(
                        reference: reference,
                        platform: platform,
                        containerSystemConfig: containerSystemConfig,
                        progressUpdate: { progressEvents in
                            for event in progressEvents {
                                switch event {
                                case .setDescription(let description),
                                    .setSubDescription(let description),
                                    .setItemsName(let description),
                                    .custom(let description):
                                    continuation.yield(description)
                                case .addTotalSize(let size),
                                    .setTotalSize(let size),
                                    .addSize(let size),
                                    .setSize(let size):
                                    let humanReadableSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                                    continuation.yield("Downloaded \(humanReadableSize)")
                                case .addTotalItems(let items),
                                    .setTotalItems(let items),
                                    .addItems(let items),
                                    .setItems(let items):
                                    continuation.yield("Processing \(items) layer\(items == 1 ? "" : "s")")
                                default:
                                    break
                                }
                            }
                        }
                    )
                    continuation.yield("Unpacking image")
                    try await image.unpack(platform: platform, progressUpdate: nil)
                    logger.info("Successfully pulled image \(reference) for platform \(platform.description)")
                    continuation.yield("Image digest: \(image.digest)")
                    continuation.finish()
                } catch {
                    // On arm64 hosts: if the image has no arm64 variant, fall back to amd64 (Rosetta).
                    // Apple Container enables Rosetta automatically when the container platform is amd64.
                    let errMsg = String(describing: error)
                    if platform.architecture == "arm64",
                        errMsg.contains("does not support required platforms")
                    {
                        let amd64 = Platform(arch: "amd64", os: platform.os, variant: nil)
                        logger.info("arm64 not available for \(reference), retrying with amd64 (Rosetta)")
                        continuation.yield("linux/arm64 not available — retrying with linux/amd64 (Rosetta)")
                        do {
                            let fallbackImage = try await ClientImage.pull(
                                reference: reference,
                                platform: amd64,
                                containerSystemConfig: containerSystemConfig,
                                progressUpdate: nil
                            )
                            try await fallbackImage.unpack(platform: amd64, progressUpdate: nil)
                            logger.info("Successfully pulled \(reference) for amd64 (Rosetta)")
                            continuation.yield("Image digest: \(fallbackImage.digest)")
                            continuation.finish()
                        } catch let fallbackError {
                            logger.error("amd64 fallback also failed for \(reference): \(fallbackError)")
                            continuation.yield(String(describing: fallbackError))
                            continuation.finish(throwing: fallbackError)
                        }
                    } else {
                        logger.error("Failed to pull image \(reference): \(error)")
                        continuation.yield(errMsg)
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    > {
        let normalizedReference = try ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig)

        logger.info("Pushing image reference: \(normalizedReference)")

        let image: ClientImage
        do {
            image = try await ClientImage.get(reference: normalizedReference, containerSystemConfig: containerSystemConfig)
        } catch {
            logger.error("Image not found: \(normalizedReference)")
            throw ClientImageError.notFound(id: normalizedReference)
        }

        logger.debug("Image reference from ClientImage: \(image.reference)")

        let effectivePlatform = try await resolvedPushPlatform(for: image, requestedPlatform: platform, logger: logger)

        return AsyncThrowingStream { continuation in
            let platformDesc = effectivePlatform?.description ?? "default"
            logger.info("Starting to push image \(normalizedReference) for platform \(platformDesc)")
            logger.info("Retrieved image object with reference: \(image.reference)")
            continuation.yield("Trying to push \(normalizedReference)")
            Task {
                do {
                    try await image.push(
                        platform: effectivePlatform,
                        scheme: .auto,
                        containerSystemConfig: containerSystemConfig,
                        progressUpdate: { progressEvents in
                            for event in progressEvents {
                                switch event {
                                case .setDescription(let description),
                                    .setSubDescription(let description),
                                    .setItemsName(let description),
                                    .custom(let description):
                                    continuation.yield(description)
                                case .addTotalSize(let size),
                                    .setTotalSize(let size),
                                    .addSize(let size),
                                    .setSize(let size):
                                    let humanReadableSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                                    continuation.yield("Uploaded \(humanReadableSize)")
                                case .addTotalItems(let items),
                                    .setTotalItems(let items),
                                    .addItems(let items),
                                    .setItems(let items):
                                    continuation.yield("Pushing \(items) layer\(items == 1 ? "" : "s")")
                                default:
                                    break
                                }
                            }
                        }
                    )
                    logger.info("Successfully pushed image \(normalizedReference) for platform \(platformDesc)")
                    continuation.yield("Successfully pushed \(normalizedReference)")
                    continuation.finish()
                } catch {
                    logger.error("Failed to push image \(normalizedReference): \(error)")

                    // Check if this is a "notFound: Content with digest" error (missing layer data)
                    let errorDescription = String(describing: error)
                    if errorDescription.contains("notFound") && errorDescription.contains("Content with digest") {
                        let message =
                            "Failed to push image: One or more layers are missing from the image store. "
                            + "This is a known limitation of Apple's Containerization framework when working with tagged images. "
                            + "The tag metadata exists but the underlying layer data is not properly linked. " + "Original error: \(errorDescription)"
                        continuation.yield(message)
                    } else {
                        continuation.yield(String(describing: error))
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func prune(filters: [String: [String]], logger: Logger) async throws -> (deletedImages: [String], spaceReclaimed: Int64) {
        let allImages = try await list()
        var imagesToDelete: [ClientImage] = []

        let allContainers = try await ContainerClient().list()
        let imagesInUse = Set(allContainers.map { $0.configuration.image.reference })

        for image in allImages {
            var shouldDelete = false
            let reference = image.reference

            do {
                _ = try await image.index()

                if imagesInUse.contains(reference) {
                    continue
                }

                let isDangling = reference.contains("<none>") || reference.contains("@sha256:")

                if let danglingFilters = filters["dangling"] {
                    if let danglingValue = danglingFilters.first {
                        let shouldBeDangling = (danglingValue == "true" || danglingValue == "1")
                        if shouldBeDangling {
                            shouldDelete = isDangling
                        } else {
                            shouldDelete = true
                        }
                    }
                } else {
                    shouldDelete = isDangling
                }

                var imageConfig: ContainerizationOCI.Image?
                if shouldDelete && (filters["label"] != nil || filters["until"] != nil) {
                    // Get the config for the first available platform
                    let manifests = try await image.index().manifests

                    for descriptor in manifests {
                        guard let platform = descriptor.platform else { continue }

                        do {
                            imageConfig = try await image.config(for: platform)
                            break
                        } catch {
                            continue
                        }
                    }
                }

                if shouldDelete, let labelFilters = filters["label"], let config = imageConfig {
                    var allLabelsMatch = true
                    for labelFilter in labelFilters {
                        if let eqIdx = labelFilter.firstIndex(of: "=") {
                            let key = String(labelFilter[..<eqIdx])
                            let value = String(labelFilter[labelFilter.index(after: eqIdx)...])
                            if config.config?.labels?[key] != value {
                                allLabelsMatch = false
                                break
                            }
                        } else {
                            if config.config?.labels?[labelFilter] == nil {
                                allLabelsMatch = false
                                break
                            }
                        }
                    }

                    shouldDelete = shouldDelete && allLabelsMatch
                }

                if shouldDelete, let untilFilters = filters["until"], let config = imageConfig {
                    let createdIso8601 = config.created ?? "1970-01-01T00:00:00Z"

                    let iso8601Formatter = ISO8601DateFormatter()
                    iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var imageCreationDate = iso8601Formatter.date(from: createdIso8601)

                    if imageCreationDate == nil {
                        iso8601Formatter.formatOptions = [.withInternetDateTime]
                        imageCreationDate = iso8601Formatter.date(from: createdIso8601)
                    }

                    if let imageCreationDate = imageCreationDate {
                        var matchesUntil = false

                        for untilValue in untilFilters {
                            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            var untilDate = iso8601Formatter.date(from: untilValue)

                            if untilDate == nil {
                                iso8601Formatter.formatOptions = [.withInternetDateTime]
                                untilDate = iso8601Formatter.date(from: untilValue)
                            }

                            if untilDate == nil {
                                if let unixTimestamp = TimeInterval(untilValue) {
                                    untilDate = Date(timeIntervalSince1970: unixTimestamp)
                                }
                            }

                            if let untilDate = untilDate {
                                if imageCreationDate < untilDate {
                                    matchesUntil = true
                                    break
                                }
                            } else {
                                logger.warning("Failed to parse until timestamp: \(untilValue)")
                            }
                        }

                        shouldDelete = shouldDelete && matchesUntil
                    } else {
                        logger.warning("Failed to parse image creation date: \(createdIso8601)")
                        shouldDelete = false
                    }
                }

            } catch {
                logger.warning("Failed to get details for image \(image.reference): \(error)")
                continue
            }

            if shouldDelete {
                imagesToDelete.append(image)
            }
        }

        var deletedImages: [String] = []
        var spaceReclaimed: Int64 = 0

        for image in imagesToDelete {
            do {
                let reference = image.reference

                let manifests = try await image.index().manifests

                for descriptor in manifests {
                    if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                        referenceType == "attestation-manifest"
                    {
                        continue
                    }

                    guard let platform = descriptor.platform else {
                        continue
                    }

                    do {
                        let manifest = try await image.manifest(for: platform)
                        // Calculate size: descriptor + config + all layers
                        let imageSize = descriptor.size + manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
                        spaceReclaimed += imageSize
                    } catch {
                        continue
                    }
                }

                try await delete(id: reference)
                deletedImages.append(reference)
            } catch {
                logger.warning("Failed to delete image \(image.reference): \(error)")
            }
        }

        return (deletedImages, spaceReclaimed)
    }

    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] {
        let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let extractedPath = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractedPath, withIntermediateDirectories: true)

        try ArchiveUtility.extract(tarPath: tarballPath, to: extractedPath)

        // `docker buildx build --load`, the containerd "docker" exporter, and
        // `docker save` on modern Docker emit a tarball that is already a valid
        // OCI image layout (an `oci-layout` marker, an `index.json`, and blobs
        // under `blobs/sha256/`). Such tarballs also include a legacy
        // `manifest.json` for backwards compatibility, but its `Config`/`Layers`
        // entries point at `blobs/sha256/<digest>` rather than the legacy
        // `<digest>.json` / `<digest>/layer.tar` paths, so the docker-archive
        // converter cannot consume them. Load the OCI layout directly and only
        // fall back to conversion for genuinely legacy docker-archive tarballs.
        let ociLayoutPath: URL
        let hasOCILayout =
            FileManager.default.fileExists(atPath: extractedPath.appendingPathComponent("oci-layout").path)
            && FileManager.default.fileExists(atPath: extractedPath.appendingPathComponent("index.json").path)

        if hasOCILayout {
            ociLayoutPath = extractedPath
        } else {
            ociLayoutPath = tempDir.appendingPathComponent("oci-layout")
            try FileManager.default.createDirectory(at: ociLayoutPath, withIntermediateDirectories: true)
            _ = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: extractedPath,
                ociLayoutPath: ociLayoutPath,
                logger: logger
            )
        }

        let images = try await imageStore.load(
            from: ociLayoutPath,
            progress: { progressEvents in
                for event in progressEvents {
                    logger.debug("Load progress event: \(event.event) = \(event.value)")
                }
            })

        let loadedImages = images.map { $0.reference }
        for image in loadedImages {
            logger.info("Loaded image: \(image)")
        }

        logger.info("Successfully loaded \(images.count) image(s) from tarball")

        return loadedImages
    }

    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let exportPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: exportPath, withIntermediateDirectories: true)

        var resolvedRefs: [String] = []

        for reference in references {
            do {
                let image = try await ClientImage.get(reference: reference, containerSystemConfig: containerSystemConfig)
                logger.debug("Image exists: \(image.reference)")
                resolvedRefs.append(image.reference)
            } catch {
                logger.error("Image not found: \(reference)")
                throw ClientImageError.notFound(id: reference)
            }
        }

        do {
            try await imageStore.save(
                references: resolvedRefs,
                out: exportPath,
                platform: platform
            )
        } catch {
            let errorDescription = String(describing: error)
            logger.error("Failed to export images: \(errorDescription)")

            if errorDescription.contains("notFound") && errorDescription.localizedCaseInsensitiveContains("content with digest") {
                let detailedMessage =
                    "Export failed: ContentStore missing blob data. This is a limitation of Apple's Containerization framework. The image metadata exists but the underlying content blobs are not available."
                logger.error("\(detailedMessage)")
                throw ClientImageError.notFound(id: detailedMessage)
            }
            throw error
        }

        let dockerFormatPath = tempDir.appendingPathComponent("docker-format")
        try FileManager.default.createDirectory(at: dockerFormatPath, withIntermediateDirectories: true)

        let dockerManifests = try await ContainerImageUtility.convertOCIToDockerTar(
            ociLayoutPath: exportPath,
            dockerFormatPath: dockerFormatPath,
            resolvedRefs: resolvedRefs,
            logger: logger
        )

        let dockerManifestData = try JSONSerialization.data(withJSONObject: dockerManifests, options: [.prettyPrinted])
        try dockerManifestData.write(to: dockerFormatPath.appendingPathComponent("manifest.json"))

        let tarballPath = tempDir.appendingPathComponent("images.tar")

        try ArchiveUtility.create(tarPath: tarballPath, from: dockerFormatPath)

        logger.info("Successfully exported \(references.count) image(s) to tarball in Docker format")

        return tarballPath
    }
}
