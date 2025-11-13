import ContainerClient
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

protocol ClientImageProtocol: Sendable {
    func list() async throws -> [ClientImage]
    func delete(id: String) async throws
    func pull(image: String, tag: String?, platform: Platform, registryAuth: AuthConfig?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    >
    func push(reference: String, platform: Platform?, registryAuth: AuthConfig?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    >
    func prune(filters: [String: [String]], logger: Logger) async throws -> (deletedImages: [String], spaceReclaimed: Int64)
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String]
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL
}

enum ClientImageError: Error {
    case notFound(id: String)
}

struct ClientImageService: ClientImageProtocol {

    func list() async throws -> [ClientImage] {
        let allImages = try await ClientImage.list()
        // filter out infra images
        // also filter images based on digests
        let filteredImages = allImages.filter { img in
            let ref = img.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDigest = ref.contains("@sha256:")
            let isInfra = Utility.isInfraImage(name: ref)
            return isDigest || !isInfra
        }
        return filteredImages
    }

    func delete(id: String) async throws {
        do {
            _ = try await ClientImage.get(reference: id)
        } catch {
            // Handle specific error if needed
            throw ClientImageError.notFound(id: id)
        }
        try await ClientImage.delete(reference: id, garbageCollect: false)
    }

    func pull(image: String, tag: String?, platform: Platform, registryAuth: AuthConfig?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    > {
        let normalizedImage = ContainerImageUtility.normalizeImageReference(image)
        let reference: String
        if let tag = tag, !tag.isEmpty {
            if tag.starts(with: "sha256:") {
                reference = "\(normalizedImage)@\(tag)"
            } else {
                reference = "\(normalizedImage):\(tag)"
            }
        } else {
            reference = normalizedImage
        }

        logger.info("Pulling image reference: \(reference)")

        // Create authentication from X-Registry-Auth header if provided
        let authentication: Authentication? = {
            guard let auth = registryAuth else {
                logger.debug("No registry authentication provided")
                return nil
            }

            guard let username = auth.username, let password = auth.password else {
                logger.debug("Registry auth missing username or password")
                return nil
            }

            logger.debug("Creating BasicAuthentication for user: \(username)")
            return BasicAuthentication(username: username, password: password)
        }()

        return AsyncThrowingStream { continuation in
            logger.info("Starting to pull image \(reference) for platform \(platform.description)")
            continuation.yield("Trying to pull \(reference)")
            Task {
                do {
                    let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

                    let image = try await imageStore.pull(
                        reference: reference,
                        platform: platform,
                        insecure: false,  //Should be revisited later
                        auth: authentication,
                        progress: { progressEvents in
                            for event in progressEvents {
                                switch event.event {
                                case "add-total-size":
                                    if let size = event.value as? UInt64 {
                                        let humanReadableSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                                        let message = "Downloaded \(humanReadableSize)"
                                        continuation.yield(message)
                                    } else if let size = event.value as? Int64 {
                                        let humanReadableSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                                        let message = "Downloaded \(humanReadableSize)"
                                        continuation.yield(message)
                                    }
                                case "add-total-items":
                                    if let items = event.value as? Int {
                                        let message = "Processing \(items) layer\(items == 1 ? "" : "s")"
                                        continuation.yield(message)
                                    }
                                default:
                                    logger.debug("Progress event: \(event.event) = \(event.value)")
                                }
                            }
                        }
                    )
                    logger.info("Successfully pulled image \(reference) for platform \(platform.description)")
                    continuation.yield("Image digest: \(image.digest)")
                    continuation.finish()
                } catch {
                    logger.error("Failed to pull image \(reference): \(error)")
                    continuation.yield(String(describing: error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func push(reference: String, platform: Platform?, registryAuth: AuthConfig?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    > {
        let normalizedReference = ContainerImageUtility.normalizeImageReference(reference)

        logger.info("Pushing image reference: \(normalizedReference)")

        let image: ClientImage
        do {
            image = try await ClientImage.get(reference: normalizedReference)
        } catch {
            logger.error("Image not found: \(normalizedReference)")
            throw ClientImageError.notFound(id: normalizedReference)
        }

        logger.debug("Image reference from ClientImage: \(image.reference)")

        // WARN: Tagged images may fail to push if layers are not properly linked
        //       in Apple's ImageStore. This is a limitation of the Containerization framework.

        let authentication: Authentication? = {
            guard let auth = registryAuth else {
                logger.debug("No registry authentication provided")
                return nil
            }

            guard let username = auth.username, let password = auth.password else {
                logger.debug("Registry auth missing username or password")
                return nil
            }

            logger.debug("Creating BasicAuthentication for user: \(username)")
            return BasicAuthentication(username: username, password: password)
        }()

        return AsyncThrowingStream { continuation in
            let platformDesc = platform?.description ?? "default"
            logger.info("Starting to push image \(normalizedReference) for platform \(platformDesc)")
            logger.info("Retrieved image object with reference: \(image.reference)")
            continuation.yield("Trying to push \(normalizedReference)")
            Task {
                do {
                    let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

                    try await imageStore.push(
                        reference: normalizedReference,
                        platform: platform,
                        insecure: false,  //Should be revisited later
                        auth: authentication,
                        progress: { progressEvents in
                            for event in progressEvents {
                                switch event.event {
                                case "add-total-size":
                                    if let size = event.value as? UInt64 {
                                        let humanReadableSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                                        let message = "Uploaded \(humanReadableSize)"
                                        continuation.yield(message)
                                    } else if let size = event.value as? Int64 {
                                        let humanReadableSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                                        let message = "Uploaded \(humanReadableSize)"
                                        continuation.yield(message)
                                    }
                                case "add-total-items":
                                    if let items = event.value as? Int {
                                        let message = "Pushing \(items) layer\(items == 1 ? "" : "s")"
                                        continuation.yield(message)
                                    }
                                default:
                                    logger.debug("Progress event: \(event.event) = \(event.value)")
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

        let allContainers = try await ClientContainer.list()
        let imagesInUse = Set(allContainers.map { $0.configuration.image.reference })

        for image in allImages {
            var shouldDelete = false
            let reference = image.reference

            do {
                _ = try await image.details()

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

        let dockerFormatPath = tempDir.appendingPathComponent("docker-format")
        try FileManager.default.createDirectory(at: dockerFormatPath, withIntermediateDirectories: true)

        try TarUtility.extract(tarPath: tarballPath, to: dockerFormatPath)

        let ociLayoutPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: ociLayoutPath, withIntermediateDirectories: true)

        let loadedImages = try await ContainerImageUtility.convertDockerTarToOCI(
            dockerFormatPath: dockerFormatPath,
            ociLayoutPath: ociLayoutPath,
            logger: logger
        )

        let images = try await imageStore.load(
            from: ociLayoutPath,
            progress: { progressEvents in
                for event in progressEvents {
                    logger.debug("Load progress event: \(event.event) = \(event.value)")
                }
            })

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
            let candidatesToTry: [String] = {
                var candidates: [String] = []

                candidates.append(reference)

                if !reference.contains(":") && !reference.contains("@sha256:") {
                    candidates.append("\(reference):latest")
                }

                let normalized = ContainerImageUtility.normalizeImageReference(reference)
                if normalized != reference {
                    candidates.append(normalized)
                    if !normalized.contains(":") && !normalized.contains("@sha256:") {
                        candidates.append("\(normalized):latest")
                    }
                }

                return candidates
            }()

            var resolved = false
            for candidate in candidatesToTry {
                do {
                    _ = try await ClientImage.get(reference: candidate)
                    logger.debug("Image exists: \(candidate)")
                    resolvedRefs.append(candidate)
                    resolved = true
                    break
                } catch {
                    continue
                }
            }

            if !resolved {
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

        try TarUtility.create(tarPath: tarballPath, from: dockerFormatPath)

        logger.info("Successfully exported \(references.count) image(s) to tarball in Docker format")

        return tarballPath
    }
}
