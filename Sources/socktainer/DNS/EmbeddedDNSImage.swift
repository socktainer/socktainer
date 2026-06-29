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
            let loaded = try await imageClient.load(
                tarballPath: resourceURL,
                platform: .current,
                appleContainerAppSupportUrl: appSupportURL,
                logger: log
            )

            // The OCI archive carries no repo:tag, so the image lands in the store
            // untagged and cannot be resolved as `socktainer-dns:embedded`. Tag the
            // freshly-loaded image so the forwarder can reference it locally
            // (otherwise creating the DNS container falls back to a registry pull).
            // Fail loudly if the import produced no image rather than reporting a
            // readiness we cannot back.
            guard let loadedRef = loaded.first else {
                throw EmbeddedDNSError.importReturnedNoImage
            }
            let loadedImage = try await ClientImage.get(reference: loadedRef, containerSystemConfig: containerSystemConfig)
            _ = try await loadedImage.tag(new: tag)

            // The tag is written over XPC, but the image list a later
            // `ClientImage.get(reference: tag)` reads can lag briefly. Confirm the tag
            // resolves before returning so the caller (NetworkDNSManager) can't miss it
            // and silently skip the DNS sidecar on the first `compose up`.
            for attempt in 0..<tagVisibilityMaxAttempts {
                // Sleep before every check except the first, so the final check happens
                // after the last sleep — a tag that appears at the end of the budget is
                // still caught rather than treated as a timeout.
                if attempt > 0 {
                    try await Task.sleep(for: tagVisibilityPollInterval)
                }
                if (try? await ClientImage.get(reference: tag, containerSystemConfig: containerSystemConfig)) != nil {
                    log.info("[dns-embedded] DNS forwarder image ready: \(tag)")
                    return
                }
            }
            // Tag write succeeded but the list still hasn't caught up within the budget.
            // Don't fail setup over it: return and let the caller proceed. Its lookup
            // either now sees the tag (DNS set up) or falls back to starting the
            // container without DNS — the same graceful degradation as before — and a
            // later `compose up` resolves once the image list catches up.
            log.warning("[dns-embedded] tag \(tag) not yet resolvable within budget; proceeding (DNS may be set up on a later run)")
        }
    }

    // The embedded image tag is confirmed visible within this budget (~2s) before
    // ensure() returns; see the poll loop above.
    private static let tagVisibilityMaxAttempts = 100
    private static let tagVisibilityPollInterval: Duration = .milliseconds(20)

    enum EmbeddedDNSError: Error {
        /// The embedded archive was loaded but produced no image reference to tag.
        case importReturnedNoImage
    }
}
