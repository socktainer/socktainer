import ContainerAPIClient
import ContainerResource
import Darwin
import Foundation
import Logging

/// Removes only the old relay resources owned by this metadata directory.
///
/// This is a one-shot resource migration, not a compatibility implementation:
/// native Apple forwarding is the only published-port path after startup. The
/// owner label prevents a new daemon from deleting another daemon's resources
/// when multiple isolated metadata registries share the Apple service.
enum ObsoleteRelayResourceMigration {
    private static let roleLabel = "socktainer.role"
    private static let relayRole = "relay"
    private static let ownerLabel = "socktainer.relay.owner"

    static func removeOwnedResources(ownerID: String, logger: Logger) async {
        let client = ContainerClient()
        if let containers = try? await client.list() {
            for container in containers where isOwnedRelay(container, ownerID: ownerID) {
                if container.status == .running {
                    try? await client.stop(id: container.id)
                }
                do {
                    try await client.delete(id: container.id)
                    logger.info("[startup] removed obsolete published-port relay \(container.id)")
                } catch {
                    logger.warning(
                        "[startup] could not remove obsolete relay \(container.id): \(error)"
                    )
                }
            }
        }

        // The old manager used this exact owner-scoped directory for published
        // Unix sockets. It contains no current Socktainer state and is safe to
        // remove after the corresponding containers have been retired.
        let oldRuntimeRoot = URL(
            fileURLWithPath: "/tmp/socktainer-relay-\(getuid())-\(ownerID)",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: oldRuntimeRoot)
    }

    static func isOwnedRelay(_ snapshot: ContainerSnapshot, ownerID: String) -> Bool {
        snapshot.configuration.labels[roleLabel] == relayRole
            && snapshot.configuration.labels[ownerLabel] == ownerID
    }
}
