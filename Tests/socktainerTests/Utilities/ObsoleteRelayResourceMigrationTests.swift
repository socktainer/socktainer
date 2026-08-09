import ContainerResource
import Testing

@testable import socktainer

@Suite("Obsolete relay resource migration")
struct ObsoleteRelayResourceMigrationTests {
    @Test("matches only relay resources owned by the current metadata registry")
    func ownershipScope() throws {
        let owned = try makeContainerSnapshot(
            nativeId: "old-relay-owned",
            networks: [(network: "default", ip: "192.168.65.4")],
            labels: [
                "socktainer.role": "relay",
                "socktainer.relay.owner": "owner-a",
            ]
        )
        let foreign = try makeContainerSnapshot(
            nativeId: "old-relay-foreign",
            networks: [(network: "default", ip: "192.168.65.5")],
            labels: [
                "socktainer.role": "relay",
                "socktainer.relay.owner": "owner-b",
            ]
        )
        let dns = try makeContainerSnapshot(
            nativeId: "dns-helper",
            networks: [(network: "default", ip: "192.168.65.6")],
            labels: [
                "socktainer.role": "dns",
                "socktainer.relay.owner": "owner-a",
            ]
        )

        #expect(ObsoleteRelayResourceMigration.isOwnedRelay(owned, ownerID: "owner-a"))
        #expect(!ObsoleteRelayResourceMigration.isOwnedRelay(foreign, ownerID: "owner-a"))
        #expect(!ObsoleteRelayResourceMigration.isOwnedRelay(dns, ownerID: "owner-a"))
    }
}
