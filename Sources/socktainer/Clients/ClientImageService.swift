import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

/// What was removed when deleting an image reference.
/// Mirrors Docker Engine's `ImageDeleteResponseItem` semantics:
///   - `untagged` — the tag that was removed (always present)
///   - `digest` — the sha256 of the image the tag pointed at (always present); Docker uses
///     this as the `Actor.ID` for `untag`/`delete` events
///   - `deletedDigest` — the sha256 of image layers freed (only when the last tag was removed)
struct ImageDeletionResult {
    let untagged: String  // normalized tag that was untagged
    let digest: String  // sha256 of the image the removed tag referenced
    let deletedDigest: String?  // sha256 if the image layers were garbage-collected
}

protocol ClientImageProtocol: Sendable {
    func list(includeSystemImages: Bool) async throws -> [ClientImage]
    func delete(id: String) async throws -> ImageDeletionResult
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<
        PullProgress, Error
    >
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    >
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64)
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String]
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL
    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String)
}

extension ClientImageProtocol {
    func list() async throws -> [ClientImage] {
        try await list(includeSystemImages: false)
    }
}

enum ClientImageError: Error {
    case notFound(id: String)
    case digestReferenceNotAllowed(repo: String)
}

enum PullProgress: Sendable {
    case message(String)
    case downloading(current: Int64, total: Int64)
    case extracting(current: Int64, total: Int64)
}

actor PullByteCounter {
    private var current: Int64 = 0
    private var total: Int64 = 0
    private var lastEmit: ContinuousClock.Instant?
    private let emitInterval: Duration

    init(emitInterval: Duration = .milliseconds(100)) {
        self.emitInterval = emitInterval
    }

    func apply(_ events: [ProgressUpdateEvent]) -> (current: Int64, total: Int64)? {
        var changed = false
        for event in events {
            switch event {
            case .addSize(let value): current += value
            case .setSize(let value): current = value
            case .addTotalSize(let value): total += value
            case .setTotalSize(let value): total = value
            default: continue
            }
            changed = true
        }
        guard changed, shouldEmitNow() else { return nil }
        lastEmit = .now
        return (current, total)
    }

    private func shouldEmitNow() -> Bool {
        if total > 0 && current >= total { return true }
        guard let lastEmit else { return true }
        return ContinuousClock.Instant.now - lastEmit >= emitInterval
    }
}

/// Seam that abstracts the static `ClientImage` API for testing.
/// The real implementation delegates to Apple Container; tests inject a fake.
protocol ImageDeletionStore: Sendable {
    /// Return the (normalizedReference, digest) for the image matching `id`.
    func normalizedReference(for id: String, config: ContainerSystemConfig) async throws -> (String, String)
    /// Return all normalized references that share the same digest.
    /// Call this AFTER delete() to determine whether the deletion freed the image layers.
    func refsForDigest(_ digest: String) async throws -> [String]
    /// Delete the image with the exact (normalized) reference from the store.
    func delete(reference: String) async throws
    /// Free orphaned blobs and snapshots no longer referenced by any image.
    /// Returns bytes reclaimed. Mirrors what Apple Container's own CLI does after
    /// every image delete or prune to actually reclaim disk space.
    func cleanUpOrphanedBlobs() async throws -> UInt64
}

/// Production implementation — delegates straight to Apple Container.
struct LiveImageDeletionStore: ImageDeletionStore {
    func normalizedReference(for id: String, config: ContainerSystemConfig) async throws -> (String, String) {
        let image = try await ClientImage.get(reference: id, containerSystemConfig: config)
        return (image.reference, image.digest)
    }

    func refsForDigest(_ digest: String) async throws -> [String] {
        let all = try await ClientImage.list()
        return all.filter { $0.digest == digest }.map { $0.reference }
    }

    func delete(reference: String) async throws {
        // garbageCollect: false — Apple Container's own CLI always uses false here.
        // Orphaned blobs are freed separately via cleanUpOrphanedBlobs().
        try await ClientImage.delete(reference: reference, garbageCollect: false)
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 {
        let (_, freed) = try await ClientImage.cleanUpOrphanedBlobs()
        return freed
    }
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

    func delete(id: String) async throws -> ImageDeletionResult {
        try await Self.delete(
            id: id,
            containerSystemConfig: containerSystemConfig
        )
    }

    /// Deletes an image by reference, normalizing the key via `imageStore`.
    ///
    /// The `imageStore` parameter is a test seam that defaults to the real
    /// `ClientImage` implementation. Inject a custom store in tests to verify
    /// that the delete call uses the normalized reference (not the raw user input).
    ///
    /// **Bug fixed**: the pre-fix implementation passed the raw user-supplied `id`
    /// directly to the store's delete method. Because tags are stored under their
    /// normalized form (e.g. `"docker.io/library/test:latest"`), a short tag like
    /// `"test:latest"` would silently miss — the delete was a no-op.
    static func delete(
        id: String,
        containerSystemConfig: ContainerSystemConfig,
        imageStore: ImageDeletionStore = LiveImageDeletionStore()
    ) async throws -> ImageDeletionResult {
        let normalizedRef: String
        let digest: String
        do {
            (normalizedRef, digest) = try await imageStore.normalizedReference(for: id, config: containerSystemConfig)
        } catch {
            throw ClientImageError.notFound(id: id)
        }
        try await imageStore.delete(reference: normalizedRef)

        // Free orphaned blobs — mirrors Apple Container's own `container image rm`.
        // Use try? so a GC failure does not fail the delete: the tag is already gone
        // and returning an error here would cause the client to retry a completed operation.
        _ = try? await imageStore.cleanUpOrphanedBlobs()

        // Check remaining refs AFTER deletion to avoid a TOCTOU race: two concurrent
        // deletes checking before either delete would both see isLastRef=false and
        // neither would GC. Checking post-delete gives the accurate remaining count.
        // Use try? — if the list call fails the tag is still gone; assume last-ref=false.
        let remainingRefs = (try? await imageStore.refsForDigest(digest)) ?? []
        let wasLastRef = remainingRefs.isEmpty

        return ImageDeletionResult(
            untagged: normalizedRef,
            digest: digest,
            deletedDigest: wasLastRef ? digest : nil
        )
    }

    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<
        PullProgress, Error
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
            continuation.yield(.message("Trying to pull \(reference)"))
            Task {
                do {
                    let byteCounter = PullByteCounter()
                    let image = try await ClientImage.pull(
                        reference: reference,
                        platform: platform,
                        containerSystemConfig: containerSystemConfig,
                        progressUpdate: { progressEvents in
                            for event in progressEvents {
                                switch event {
                                case .setDescription(let description),
                                    .setSubDescription(let description),
                                    .custom(let description):
                                    continuation.yield(.message(description))
                                default:
                                    break
                                }
                            }
                            if let bytes = await byteCounter.apply(progressEvents) {
                                continuation.yield(.downloading(current: bytes.current, total: bytes.total))
                            }
                        }
                    )
                    continuation.yield(.message("Unpacking image"))
                    let unpackCounter = PullByteCounter()
                    try await image.unpack(
                        platform: platform,
                        progressUpdate: { progressEvents in
                            if let bytes = await unpackCounter.apply(progressEvents) {
                                continuation.yield(.extracting(current: bytes.current, total: bytes.total))
                            }
                        }
                    )
                    logger.info("Successfully pulled image \(reference) for platform \(platform.description)")
                    continuation.yield(.message("Image digest: \(image.digest)"))
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
                        continuation.yield(.message("linux/arm64 not available — retrying with linux/amd64 (Rosetta)"))
                        do {
                            let fallbackImage = try await ClientImage.pull(
                                reference: reference,
                                platform: amd64,
                                containerSystemConfig: containerSystemConfig,
                                progressUpdate: nil
                            )
                            try await fallbackImage.unpack(platform: amd64, progressUpdate: nil)
                            logger.info("Successfully pulled \(reference) for amd64 (Rosetta)")
                            continuation.yield(.message("Image digest: \(fallbackImage.digest)"))
                            continuation.finish()
                        } catch let fallbackError {
                            logger.error("amd64 fallback also failed for \(reference): \(fallbackError)")
                            continuation.finish(throwing: fallbackError)
                        }
                    } else {
                        logger.error("Failed to pull image \(reference): \(error)")
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

    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
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
                        let shouldBeDangling = MobyBool.parse(danglingValue) ?? false
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

        var results: [ImageDeletionResult] = []
        var spaceReclaimed: Int64 = 0

        for image in imagesToDelete {
            do {
                let reference = image.reference

                // Calculate candidate size before deletion (manifest data unavailable after).
                // Only credited to spaceReclaimed when delete confirms the layers were freed.
                var candidateSize: Int64 = 0
                let manifests = try await image.index().manifests
                for descriptor in manifests {
                    if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                        referenceType == "attestation-manifest"
                    {
                        continue
                    }
                    guard let platform = descriptor.platform else { continue }
                    do {
                        let manifest = try await image.manifest(for: platform)
                        candidateSize += descriptor.size + manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
                    } catch { continue }
                }

                // Capture the per-image untag/delete result so the route can emit moby-faithful
                // per-image events. moby's image prune emits an `untag` per removed reference and
                // a `delete` per freed digest — never an aggregate "prune" event.
                let result = try await delete(id: reference)
                results.append(result)
                // Only count reclaimed bytes when layers were actually garbage-collected
                // (deletedDigest non-nil). An untag-only result frees no disk space.
                if result.deletedDigest != nil {
                    spaceReclaimed += candidateSize
                }
            } catch {
                logger.warning("Failed to delete image \(image.reference): \(error)")
            }
        }

        return (results, spaceReclaimed)
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
            try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: ociLayoutPath, logger: logger)
        } else {
            ociLayoutPath = tempDir.appendingPathComponent("oci-layout")
            try FileManager.default.createDirectory(at: ociLayoutPath, withIntermediateDirectories: true)
            _ = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: extractedPath,
                ociLayoutPath: ociLayoutPath,
                logger: logger
            )
        }

        // Apple's ImageStore.load imports every index.json descriptor inside ONE
        // ingest session; descriptors sharing a blob (multi-tag saves, images on a
        // common base layer) then collide with "File exists" in the ingest dir.
        // Loading one descriptor at a time gives each import a fresh session.
        let indexURL = ociLayoutPath.appendingPathComponent("index.json")
        var index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        let descriptors = index.manifests

        guard !descriptors.isEmpty else {
            throw OCILayoutPruner.PruneError.nothingLoadable
        }

        var images: [Containerization.Image] = []
        for descriptor in descriptors {
            index.manifests = [descriptor]
            try JSONEncoder().encode(index).write(to: indexURL)
            images +=
                try await imageStore.load(
                    from: ociLayoutPath,
                    progress: { progressEvents in
                        for event in progressEvents {
                            logger.debug("Load progress event: \(event.event) = \(event.value)")
                        }
                    })
        }

        let loadedImages = images.map { $0.reference }
        for image in loadedImages {
            logger.info("Loaded image: \(image)")
        }

        logger.info("Successfully loaded \(images.count) image(s) from tarball")

        return loadedImages
    }

    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
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

        return try await exportTarball(resolvedReferences: resolvedRefs, platform: platform, appleContainerAppSupportUrl: appleContainerAppSupportUrl, logger: logger)
    }

    func exportTarball(resolvedReferences: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let exportPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: exportPath, withIntermediateDirectories: true)

        do {
            try await imageStore.save(
                references: resolvedReferences,
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
            resolvedRefs: resolvedReferences,
            logger: logger
        )

        let dockerManifestData = try JSONSerialization.data(withJSONObject: dockerManifests, options: [.prettyPrinted])
        try dockerManifestData.write(to: dockerFormatPath.appendingPathComponent("manifest.json"))

        let tarballPath = tempDir.appendingPathComponent("images.tar")

        try ArchiveUtility.create(tarPath: tarballPath, from: dockerFormatPath)

        logger.info("Successfully exported \(resolvedReferences.count) image(s) to tarball in Docker format")

        return tarballPath
    }

    /// `docker import`: synthesizes a single-layer OCI image from `tarPath` (the
    /// raw `fromSrc=-` request body) and loads it into the image store the same
    /// way `load()` does. Returns the registered reference (nil if untagged) and
    /// the digest `imageStore.load` assigned — the same "id" concept `list`/
    /// `delete`/`load` already use elsewhere in this file.
    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        let reference = try resolveImportReference(repo: repo, tag: tag)

        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(changes, to: &config)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ociLayoutPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: ociLayoutPath, withIntermediateDirectories: true)

        _ = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: tarPath,
            ociLayoutPath: ociLayoutPath,
            platform: platform,
            config: config,
            message: message,
            reference: reference,
            logger: logger
        )

        let imageStore = try ImageStore(path: appleContainerAppSupportUrl)
        let images = try await imageStore.load(from: ociLayoutPath, progress: nil)
        guard let image = images.first else {
            throw ClientImageError.notFound(id: reference ?? "imported image")
        }

        logger.info("Imported image \(image.reference) (\(image.digest))")
        return (reference, image.digest)
    }

    /// Mirrors moby's `httputils.RepoTagReference`: empty repo means an
    /// untagged import; an empty tag defaults to "latest" (via
    /// `normalizeReference`'s `.normalize()`); a digest reference is rejected —
    /// `docker import` produces a new image, it cannot target an existing digest.
    private func resolveImportReference(repo: String?, tag: String?) throws -> String? {
        guard let repo, !repo.isEmpty else { return nil }
        guard !Self.isDigestReference(repo) else {
            throw ClientImageError.digestReferenceNotAllowed(repo: repo)
        }
        let raw = (tag?.isEmpty == false) ? "\(repo):\(tag!)" : repo
        return try ClientImage.normalizeReference(raw, containerSystemConfig: containerSystemConfig)
    }

    /// A Docker reference's grammar reserves `@` exclusively for introducing a
    /// digest (`name@algorithm:hex`), so its presence alone is unambiguous —
    /// matching moby's `reference.Digested` check, which isn't sha256-specific.
    static func isDigestReference(_ repo: String) -> Bool {
        repo.range(of: #"@[a-z0-9]+:[0-9a-f]+$"#, options: .regularExpression) != nil
    }
}
