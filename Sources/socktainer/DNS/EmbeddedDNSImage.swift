import ContainerAPIClient
import ContainerPersistence
import Foundation
import Logging

/// Manages the embedded minimal DNS forwarder OCI image.
///
/// The image is bundled with socktainer as a resource (`socktainer-dns-embedded.tar.gz`)
/// and imported into Apple Container's image store on first use. It replaces the
/// `coredns/coredns` image — same container-VM architecture, ~10x smaller footprint.
enum EmbeddedDNSImage {
    static let tag = "socktainer-dns:embedded"
    private static let log = Logger(label: "socktainer.dns.embedded")

    /// Ensures the embedded DNS image is available in Apple Container's image store.
    /// Imports from the bundled resource if missing. No-ops if already present.
    static func ensure(containerSystemConfig: ContainerSystemConfig) async throws {
        if (try? await ClientImage.get(reference: tag, containerSystemConfig: containerSystemConfig)) != nil {
            return  // already imported
        }

        guard let resourceURL = Bundle.module.url(forResource: "socktainer-dns-embedded", withExtension: "tar.gz") else {
            throw EmbeddedDNSError.resourceNotFound
        }

        log.info("[dns-embedded] importing embedded DNS image from bundle")
        let imageClient = ClientImageService()
        _ = try await imageClient.load(
            tarballPath: resourceURL,
            platform: .current,
            appleContainerAppSupportUrl: URL(
                fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/com.apple.container"),
            logger: log
        )
        log.info("[dns-embedded] DNS image ready: \(tag)")
    }

    enum EmbeddedDNSError: Error {
        case resourceNotFound
    }
}
