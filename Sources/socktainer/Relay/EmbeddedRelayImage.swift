import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Logging

enum EmbeddedRelayImage {
    static let tag = SocktainerRelayImage.reference
    private static let log = Logger(label: "socktainer.relay.embedded")

    actor ImportGate {
        static let shared = ImportGate()
        private var task: Task<ClientImage, Error>?
        private var expectedRootDigest: String?

        func ensureOnce(
            perform: @escaping @Sendable (String?) async throws -> ClientImage
        ) async throws -> ClientImage {
            if let task { return try await task.value }
            let expected = expectedRootDigest
            let newTask = Task { try await perform(expected) }
            task = newTask
            do {
                let image = try await newTask.value
                task = nil
                expectedRootDigest = image.digest
                return image
            } catch {
                task = nil
                throw error
            }
        }
    }

    static func ensure(
        containerSystemConfig: ContainerSystemConfig,
        appSupportURL: URL,
        imageClient: any EmbeddedDNSImageService,
        gate: ImportGate = .shared
    ) async throws -> ClientImage {
        let canonicalTag = try ClientImage.normalizeReference(
            tag,
            containerSystemConfig: containerSystemConfig
        )
        return try await gate.ensureOnce { expectedDigest in
            if let expectedDigest,
                let existing = await validatedExisting(
                    canonicalTag: canonicalTag,
                    expectedDigest: expectedDigest,
                    imageClient: imageClient
                )
            {
                return existing
            }
            let prepared = try prepareLoadableArchive(canonicalTag: canonicalTag)
            defer { try? FileManager.default.removeItem(at: prepared.directory) }
            let loaded = try await imageClient.load(
                tarballPath: prepared.archive,
                platform: .current,
                appleContainerAppSupportUrl: appSupportURL,
                logger: log
            )
            guard let loadedReference = loaded.first else {
                throw RelayImageError.importReturnedNoImage
            }
            return try await imageClient.tag(source: loadedReference, target: tag).image
        }
    }

    private static func validatedExisting(
        canonicalTag: String,
        expectedDigest: String,
        imageClient: any EmbeddedDNSImageService
    ) async -> ClientImage? {
        guard let inventory = try? await imageClient.imageStoreInventory(includeSystemImages: true) else {
            return nil
        }
        let owners = Set(
            inventory.physicalReferencesByRootDigest.compactMap { digest, references in
                references.contains(canonicalTag) ? digest : nil
            }
        )
        guard owners == [expectedDigest] else { return nil }
        return inventory.images.first {
            $0.reference == canonicalTag && $0.digest == expectedDigest
        }
    }

    static func prepareLoadableArchive(
        canonicalTag: String
    ) throws -> (archive: URL, directory: URL) {
        let directory = try RequestBodyFileWriter.createSecureTemporaryDirectory()
        do {
            let source = directory.appendingPathComponent("bundled-relay.tar.gz")
            try SocktainerRelayImage.archiveData.write(to: source, options: .atomic)
            let layout = directory.appendingPathComponent("layout")
            try ArchiveUtility.extract(
                tarPath: source,
                to: layout,
                limits: .imageLoad,
                transactional: true
            )
            let indexURL = layout.appendingPathComponent("index.json")
            var index = try JSONDecoder().decode(
                Index.self,
                from: BoundedFileReader.readImageMetadata(
                    relativePath: "index.json",
                    under: layout
                )
            )
            guard index.manifests.count == 1 else { throw RelayImageError.invalidArchive }
            var descriptor = index.manifests[0]
            let platform = try runnablePlatform(for: descriptor, under: layout)
            guard platform == .current else {
                throw RelayImageError.unsupportedPlatform(platform)
            }
            descriptor.platform = platform
            var annotations = descriptor.annotations ?? [:]
            annotations[AnnotationKeys.containerizationImageName] = canonicalTag
            annotations[AnnotationKeys.containerdImageName] = canonicalTag
            annotations[AnnotationKeys.openContainersImageName] = canonicalTag
            descriptor.annotations = annotations
            index.manifests = [descriptor]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
            let archive = directory.appendingPathComponent("embedded-relay.tar")
            try ArchiveUtility.create(tarPath: archive, from: layout)
            return (archive, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func runnablePlatform(
        for descriptor: Descriptor,
        under layout: URL
    ) throws -> Platform {
        let data = try readBlob(descriptor.digest, under: layout)
        if descriptor.mediaType == MediaTypes.index
            || descriptor.mediaType == MediaTypes.dockerManifestList
        {
            let nested = try JSONDecoder().decode(Index.self, from: data)
            let candidates = nested.manifests.filter {
                $0.platform == nil || $0.platform == .current
            }
            guard candidates.count == 1 else { throw RelayImageError.invalidArchive }
            return try runnablePlatform(for: candidates[0], under: layout)
        }
        guard
            descriptor.mediaType == MediaTypes.imageManifest
                || descriptor.mediaType == MediaTypes.dockerManifest
        else {
            throw RelayImageError.invalidArchive
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let config = try JSONDecoder().decode(
            ContainerizationOCI.Image.self,
            from: readBlob(manifest.config.digest, under: layout)
        )
        return Platform(arch: config.architecture, os: config.os, variant: config.variant)
    }

    private static func readBlob(_ digest: String, under layout: URL) throws -> Data {
        guard DockerImageReferenceSemantics.isBareSHA256Identifier(digest) else {
            throw RelayImageError.invalidArchive
        }
        return try BoundedFileReader.readImageMetadata(
            relativePath: "blobs/sha256/\(digest.dropFirst("sha256:".count))",
            under: layout
        )
    }

    enum RelayImageError: Error {
        case importReturnedNoImage
        case invalidArchive
        case unsupportedPlatform(Platform)
    }
}
