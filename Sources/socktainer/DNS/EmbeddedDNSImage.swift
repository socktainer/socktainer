import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Logging
import SocktainerDNSImage

protocol EmbeddedDNSImageService: ImageStoreInventoryProviding,
    ImageTaggingProtocol
{
    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> [String]
}

extension ClientImageService: EmbeddedDNSImageService {}

enum EmbeddedDNSImage {
    static let tag = SocktainerDNSImage.reference
    private static let log = Logger(label: "socktainer.dns.embedded")

    actor ImportGate {
        static let shared = ImportGate()
        private var task: Task<ClientImage, Error>?
        private var expectedRootDigest: String?

        func ensureOnce(
            perform: @escaping @Sendable (String?) async throws -> ClientImage
        ) async throws -> ClientImage {
            if let existing = task {
                return try await existing.value
            }
            let expected = expectedRootDigest
            let t = Task { try await perform(expected) }
            task = t
            do {
                let image = try await t.value
                // This is a single-flight gate, not an image cache. A ClientImage is only
                // a handle to mutable store state and can become stale after tag replacement,
                // removal, or an Apple Container service restart. Clearing the completed task
                // makes every later ensure() revalidate the physical image association while
                // still coalescing callers that overlap with this import.
                task = nil
                // Caching immutable content identity is safe. It lets subsequent
                // networks validate tag ownership without re-importing the archive,
                // while a new Socktainer process imports once to bind the tag to the
                // image bundled in that exact binary version.
                expectedRootDigest = image.digest
                return image
            } catch {
                task = nil
                throw error
            }
        }
    }

    /// Returns the freshly-tagged handle directly: a get-by-tag right after tagging can miss on a cold store.
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
        return try await gate.ensureOnce { expectedRootDigest in
            if let expectedRootDigest,
                let image = await validatedExistingImage(
                    canonicalTag: canonicalTag,
                    expectedRootDigest: expectedRootDigest,
                    imageClient: imageClient
                )
            {
                return image
            }
            return try await importAndTag(
                containerSystemConfig: containerSystemConfig,
                appSupportURL: appSupportURL,
                imageClient: imageClient
            )
        }
    }

    private static func validatedExistingImage(
        canonicalTag: String,
        expectedRootDigest: String,
        imageClient: any EmbeddedDNSImageService
    ) async -> ClientImage? {
        guard
            let inventory = try? await imageClient.imageStoreInventory(
                includeSystemImages: true
            )
        else { return nil }
        let exactOwnerRoots = Set(
            inventory.physicalReferencesByRootDigest.compactMap {
                rootDigest, references in
                references.contains(canonicalTag) ? rootDigest : nil
            }
        )
        guard exactOwnerRoots == [expectedRootDigest] else { return nil }
        return inventory.images.first {
            $0.reference == canonicalTag
                && $0.digest == expectedRootDigest
        }
    }

    private static func importAndTag(
        containerSystemConfig: ContainerSystemConfig,
        appSupportURL: URL,
        imageClient: any EmbeddedDNSImageService
    ) async throws -> ClientImage {
        log.info("[dns-embedded] importing embedded DNS forwarder image")
        let prepared = try prepareLoadableArchive(
            canonicalTag: try ClientImage.normalizeReference(
                tag,
                containerSystemConfig: containerSystemConfig
            )
        )
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let loaded = try await imageClient.load(
            tarballPath: prepared.archive,
            platform: .current,
            appleContainerAppSupportUrl: appSupportURL,
            logger: log
        )
        guard let loadedRef = loaded.first else {
            throw EmbeddedDNSError.importReturnedNoImage
        }
        let tagged = try await imageClient.tag(source: loadedRef, target: tag)
        log.info("[dns-embedded] DNS forwarder image ready: \(tag)")
        return tagged.image
    }

    /// Buildah's embedded single-manifest OCI archive carries architecture in
    /// its config blob but omits the optional platform/name fields on the
    /// top-level descriptor. Docker load archives normally include both. Add
    /// those transport annotations in a private copy so the general image-load
    /// path can remain strict about platformless, untagged user archives.
    static func prepareLoadableArchive(
        canonicalTag: String
    ) throws -> (archive: URL, directory: URL) {
        let directory =
            try RequestBodyFileWriter
            .createSecureTemporaryDirectory()
        do {
            // The dependency's archiveURL() uses a predictable process-shared
            // temporary path. Production, staged QA, and an overlapping upgrade
            // must each consume the bytes compiled into their own executable.
            let sourceArchive = directory.appendingPathComponent(
                "bundled-dns.tar.gz"
            )
            try SocktainerDNSImage.archiveData.write(
                to: sourceArchive,
                options: .atomic
            )
            let layout = directory.appendingPathComponent("layout")
            try ArchiveUtility.extract(
                tarPath: sourceArchive,
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
            guard index.manifests.count == 1 else {
                throw EmbeddedDNSError.invalidArchive
            }
            var descriptor = index.manifests[0]
            let manifest = try JSONDecoder().decode(
                Manifest.self,
                from: readEmbeddedBlob(
                    descriptor.digest,
                    under: layout
                )
            )
            let config = try JSONDecoder().decode(
                ContainerizationOCI.Image.self,
                from: readEmbeddedBlob(
                    manifest.config.digest,
                    under: layout
                )
            )
            let platform = Platform(
                arch: config.architecture,
                os: config.os,
                variant: config.variant
            )
            guard platform == .current else {
                throw EmbeddedDNSError.unsupportedPlatform(platform)
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
            try encoder.encode(index).write(
                to: indexURL,
                options: .atomic
            )
            let archive = directory.appendingPathComponent("embedded-dns.tar")
            try ArchiveUtility.create(tarPath: archive, from: layout)
            return (archive, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func readEmbeddedBlob(
        _ digest: String,
        under layout: URL
    ) throws -> Data {
        guard DockerImageReferenceSemantics.isBareSHA256Identifier(digest)
        else { throw EmbeddedDNSError.invalidArchive }
        return try BoundedFileReader.readImageMetadata(
            relativePath: "blobs/sha256/\(digest.dropFirst("sha256:".count))",
            under: layout
        )
    }

    enum EmbeddedDNSError: Error {
        case importReturnedNoImage
        case invalidArchive
        case unsupportedPlatform(Platform)
    }
}
