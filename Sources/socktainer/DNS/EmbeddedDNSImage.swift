import ContainerAPIClient
import ContainerPersistence
import Foundation
import Logging
import SocktainerDNSImage

/// Manages the embedded DNS forwarder OCI image.
///
/// The image ships as a SwiftPM resource in the `dns-forwarder` package (swiftpm branch)
/// and is imported into Apple Container's image store on first use. Replaces the
/// `coredns/coredns` pull — no network access required at runtime.
enum EmbeddedDNSImage {
    static let tag = SocktainerDNSImage.reference
    private static let log = Logger(label: "socktainer.dns.embedded")

    /// Serializes concurrent first-use imports across all networks.
    /// Without this, two networks starting simultaneously both miss the
    /// `ClientImage.get` check and both call `load`, making startup racy.
    actor ImportGate {
        static let shared = ImportGate()
        private var task: Task<Void, Error>?

        func ensureOnce(perform: @escaping @Sendable () async throws -> Void) async throws {
            if let existing = task {
                // A prior or in-flight import — wait for it; success or failure is shared.
                try await existing.value
                return
            }
            let t = Task { try await perform() }
            task = t
            do {
                try await t.value
            } catch {
                // Reset on failure so the next caller can retry — a transient resource
                // error or store hiccup must not permanently poison every future import.
                task = nil
                throw error
            }
        }
    }

    /// Ensures the embedded DNS image is available in Apple Container's image store.
    /// Imports from the SwiftPM-bundled resource if not already present. Concurrent
    /// callers coalesce on a single import; subsequent calls return immediately once
    /// the image is in the store.
    static func ensure(
        containerSystemConfig: ContainerSystemConfig,
        appSupportURL: URL
    ) async throws {
        // Fast path: image already in store (common case after first use).
        if (try? await ClientImage.get(reference: tag, containerSystemConfig: containerSystemConfig)) != nil {
            return
        }

        // Slow path: serialize through ImportGate so concurrent first-use callers
        // don't each call load() independently.
        try await ImportGate.shared.ensureOnce {
            // Re-check inside the gate — a concurrent caller may have just loaded it.
            if (try? await ClientImage.get(reference: tag, containerSystemConfig: containerSystemConfig)) != nil {
                return
            }
            let resourceURL = SocktainerDNSImage.archiveURL
            log.info("[dns-embedded] importing embedded DNS forwarder image")
            let imageClient = ClientImageService(containerSystemConfig: containerSystemConfig)
            _ = try await imageClient.load(
                tarballPath: resourceURL,
                platform: .current,
                appleContainerAppSupportUrl: appSupportURL,
                logger: log
            )
            log.info("[dns-embedded] DNS forwarder image ready: \(tag)")
        }
    }
}
