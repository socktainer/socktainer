import ContainerAPIClient
import ContainerPersistence
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
        let loaded = try await imageClient.load(
            tarballPath: try SocktainerDNSImage.archiveURL(),
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

    enum EmbeddedDNSError: Error {
        case importReturnedNoImage
    }
}
