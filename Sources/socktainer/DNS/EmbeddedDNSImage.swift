import ContainerAPIClient
import ContainerPersistence
import Foundation
import Logging
import SocktainerDNSImage

enum EmbeddedDNSImage {
    static let tag = SocktainerDNSImage.reference
    private static let log = Logger(label: "socktainer.dns.embedded")

    actor ImportGate {
        static let shared = ImportGate()
        private var task: Task<ClientImage, Error>?

        func ensureOnce(perform: @escaping @Sendable () async throws -> ClientImage) async throws -> ClientImage {
            if let existing = task {
                return try await existing.value
            }
            let t = Task { try await perform() }
            task = t
            do {
                return try await t.value
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
        imageClient: ClientImageService
    ) async throws -> ClientImage {
        let canonicalTag = try ClientImage.normalizeReference(
            tag,
            containerSystemConfig: containerSystemConfig
        )
        if let image = try? await imageClient.list(includeSystemImages: true)
            .first(where: { $0.reference == canonicalTag })
        {
            return image
        }
        return try await ImportGate.shared.ensureOnce {
            if let image = try? await imageClient.list(includeSystemImages: true)
                .first(where: { $0.reference == canonicalTag })
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

    private static func importAndTag(
        containerSystemConfig: ContainerSystemConfig,
        appSupportURL: URL,
        imageClient: ClientImageService
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
